# Blooper — Design Spec

**Tarih:** 2026-08-11
**Durum:** Adversarial review tamamlandı (2 tur + nokta-kontrol) — kullanıcı onayı bekliyor

## Ne

Claude Code'a yazdığın İngilizce prompt'lardaki dil hatalarını yakalayıp macOS menübar'ında gösteren, `.dmg` ile dağıtılan native bir menübar uygulaması.

Kullanıcı hikâyesi: Claude Code'a İngilizce yazıyorsun → bir hook mesajını arka planda küçük bir modele kontrol ettiriyor → hatalar (`I am agree → I agree`) menübar'da birikip bildirimle görünüyor → zamanla hangi hataları tekrarladığını görüyorsun.

## Hedef kitle ve önkoşullar

- macOS 14+ (Apple Silicon + Intel, universal binary). *(13 değil: `MenuBarExtra` window stili macOS 13'te programatik dismiss/boyutlanma kısıtları taşıyor; 14 bu UI yoğunluğu için gereken olgunlukta ve Intel desteğini koruyor.)*
- Claude Code kurulu ve login olmuş kullanıcı (`claude` CLI). Kontroller kullanıcının kendi Claude aboneliği/API erişimiyle çalışır; Blooper'ın kendi API anahtarı yoktur.
- Claude Code yoksa app yine açılır; onboarding "Claude Code bulunamadı" durumunu açıkça gösterir.
- **Gizlilik:** `mistakes.jsonl` prompt'lardan alınan hatalı cümle parçalarını düz metin saklar; README'de tek cümleyle belirtilir. Veri makineden dışarı çıkmaz (tek dış çağrı kullanıcının kendi `claude` CLI'ı). İç kontrol oturumları `--no-session-persistence` ile koşar — kontrol edilen prompt'lar `~/.claude/projects/` altında transcript olarak birikmez.

## Mimari

Üç parça, tek veri dosyası:

```
Claude Code (UserPromptSubmit hook)
   └─> hook.sh            — payload'ı okur, checker'ı TAM DETACH ile arka plana atar, exit 0
         └─> checker.sh   — guard → ön-filtre → claude -p (yapılandırılmış çıktı) → mistakes.jsonl
                                   │
Blooper.app (menübar) <── dosya izleme (DispatchSource) ── mistakes.jsonl
   ├─ menü UI: bugünkü sayı, hata listesi, haftalık mini grafik
   ├─ native bildirim (UserNotifications, badge fallback'li)
   ├─ hook kur/kaldır (settings.json'ı düzenler)
   └─ Markdown export
```

### Dosya yerleşimi (runtime)

| Yol | İçerik |
|-----|--------|
| `~/Library/Application Support/Blooper/bin/hook.sh` | Hook giriş noktası (app her açılışta bundle'dan senkronlar) |
| `~/Library/Application Support/Blooper/bin/checker.sh` | Asıl kontrol script'i |
| `~/Library/Application Support/Blooper/mistakes.jsonl` | Append-only hata kaydı |
| `~/Library/Application Support/Blooper/config.json` | Model adı, bildirim aç/kapa vb. |
| `~/Library/Application Support/Blooper/last-error.log` | Debug artefaktı (insan-okur). Politika: parse-fail/`.result` yazımı **truncate** eder; `claude` stderr'i **append** eder ve checker her koşuda 64KB üstünü kırpar — dosya sınırsız büyümez |

Hook, `settings.json`'a **sabit** `Application Support` yolunu yazar — app bundle yolunu değil. App taşınsa/güncellense de hook kırılmaz; app her açılışta script'lerin güncel kopyasını buraya yazar.

## Bileşenler

### 1. Blooper.app (Swift, SPM, Xcode projesi yok)

- SwiftUI `MenuBarExtra` (window style) — liste UI: başlıkta "N logged · M today", 7 günlük mini bar grafik, gün gün gruplu hata kartları (`wrong → right`, kural açıklaması, saat, tekrar sayısı `xN`).
- `LSUIElement = true` (Dock'ta görünmez). Info.plist, `bundle.sh` içinde üretilir.
- **Açılışta:** `Application Support/Blooper/` dizinini ve yoksa boş `mistakes.jsonl` + varsayılan `config.json`'ı oluşturur, script'leri senkronlar, **ondan sonra** dosya izlemeyi kurar. `DispatchSource.makeFileSystemObjectSource` fd tabanlıdır — dosya garantili var olduktan sonra açılır; `.delete`/`.rename` event'lerinde kaynak kapatılıp yeniden kurulur (izleme kopmaz).
- Yeni satır geldiğinde UI tazelenir; bildirim **best-effort**: izin verilmemişse/başarısızsa menübar ikonundaki sayaç artışı tek başına sinyaldir. `UNUserNotificationCenter` erişimi bundle kontrolüyle sarmalanır (`swift run`/çıplak binary'de crash guard — bundle dışında notification center'a hiç dokunulmaz).
- Menü aksiyonları: "Install Claude Code hook" / "Remove hook" / "Notifications on-off" / "Export Markdown" / "Launch at login" (SMAppService).
- **Hook kurulumu:** `~/.claude/settings.json` okunur, `hooks.UserPromptSubmit` dizisine şu şekilde entry eklenir (mevcut hook'lara dokunulmaz; `hooks` veya `UserPromptSubmit` anahtarı hiç yoksa oluşturulur):

  ```json
  {"hooks": [{"type": "command",
    "command": "\"$HOME/Library/Application Support/Blooper/bin/hook.sh\""}]}
  ```

  Yol boşluk içerdiği için komut **çift tırnaklı `$HOME`** ile yazılır (`~` tek tırnakta genişlemez, tırnaksız yol `Application`'da kırılır). UserPromptSubmit'te `matcher` kullanılmaz (matcher tool-event'lerine özgüdür). Yazmadan önce `settings.json.blooper-backup` alınır; parse edilemeyen settings.json'a **dokunulmaz**, kullanıcıya hata gösterilir. Kaldırma, komut yolunda `Blooper/bin/hook.sh` geçen entry'leri söker.
- **Onboarding notu:** app DMG'den doğrudan çalıştırılmışsa (app translocation) "önce /Applications'a taşı" uyarısı gösterilir — aksi halde login-item ve sabit yollar güvenilmez.

### 2. hook.sh

1. **Özyineleme guard'ı (ilk satır):** `[ -n "$BLOOPER_CHECK" ] && exit 0`. Checker'ın başlattığı `claude -p` oturumu da bu hook'u tetikler; env miras yoluyla zincir ilk adımda kesilir.
2. stdin'deki hook JSON'ından `prompt` alanını **`plutil -extract prompt raw -o - -`** ile çıkarır (macOS-yerleşik, jq bağımlılığı yok — jq macOS 13/14'te kurulu değildir; grep/sed parse'ı tırnak/çok-satır durumunda kırılır).
3. Prompt'u **benzersiz** temp dosyaya yazar — `tmpfile=$(mktemp "${TMPDIR:-/tmp}/blooper.XXXXXX")` — sabit ad kullanılmaz; eşzamanlı iki Claude oturumu / ardışık iki hızlı prompt birbirinin dosyasını ezmez. Sonra checker'ı **tam detach** ile başlatır: `checker.sh "$tmpfile" </dev/null >/dev/null 2>&1 &`. Yalnız `nohup ... &` yetmez — miras kalan stdout/stderr fd'leri kapanmazsa Claude Code EOF görmez ve **her prompt'ta 30 sn'lik hook timeout'una kadar bekler** (UserPromptSubmit default timeout 30 sn'dir); fd yönlendirmesi bu garantinin kendisidir.
4. `exit 0`. Her hata yolu fail-open.

### 3. checker.sh

1. `export BLOOPER_CHECK=1` (guard'ın kaynağı — `claude` çağrısından ÖNCE).
2. **Ön-filtre (API çağrısız):** 4 kelimeden kısa → çık. ASCII-dışı karakter oranı yüksek (Türkçe/Rusça vb.) → çık. `/` ile başlayan girdi (slash command), `#` kısayolu, salt dosya-yolu/kod ağırlıklı metin → çık.
3. `claude` binary çözümlemesi: `command -v claude` → `~/.claude/local/claude` → `~/.local/bin/claude`; bulunamazsa `last-error.log`'a not düşüp çık (PATH hook ortamında minimal olabilir).
4. **Oturum izolasyonu:** çağrıdan önce `cd "$HOME/Library/Application Support/Blooper"` — hook kullanıcının proje dizininde koşar; cd yapılmazsa iç oturum o projenin `CLAUDE.md`/`settings` bağlamını yükler. Çağrıya ek bayraklar: `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` (kullanıcının MCP server'ları boot edilmez), `--settings '{"disableAllHooks":true}'` (yabancı hook'lar iç oturumda koşmaz + B1 guard'ına ikinci savunma katmanı; üç izolasyon bayrağının davranışı implementasyonda tek smoke-test'le doğrulanır), `--no-session-persistence` (her kontrol `~/.claude/projects/` altına kalıcı transcript yazmasın — gizlilik + disk).
5. Çağrı — prompt **her zaman stdin ile** verilir (argv'ye asla shell-interpolasyonla gömülmez; ARG_MAX ve quoting/injection yüzeyi kapanır), çıktı **dosyaya yakalanır** (arka plandaki sürecin stdout'u `$(...)` ile yakalanamaz; yönlendirmesiz çıktı kaybolur → sessiz no-op):

   ```
   outfile=$(mktemp "${TMPDIR:-/tmp}/blooper-out.XXXXXX")
   claude -p --model <config.model> --output-format json \
     --system-prompt "<kontrol talimatı>" --max-turns 1 --tools "" \
     --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
     --settings '{"disableAllHooks":true}' --no-session-persistence \
     --json-schema '<aşağıdaki şema>' \
     < "$tmpfile" > "$outfile" 2>>"$SUPPORT_DIR/last-error.log" &
   pid=$!
   (sleep 30; kill "$pid" 2>/dev/null) & wpid=$!
   wait "$pid"; kill "$wpid" 2>/dev/null
   ```

   Şema: `{"type":"object","properties":{"mistakes":{"type":"array","items":{"type":"object","properties":{"wrong":{"type":"string"},"right":{"type":"string"},"rule":{"type":"string"}},"required":["wrong","right","rule"]}}},"required":["mistakes"]}`

   - `--json-schema` → çıktı garantili şemayla `.structured_output` alanında gelir; serbest-metin parse kırılganlığı ortadan kalkar. Okuma: `plutil -extract structured_output.mistakes json -o - - < "$outfile"` (son `-` stdin demektir; dosya stdin'e yönlendirilir).
   - `--system-prompt` (append değil) → default agentic sistem prompt'u taşınmaz; `--max-turns 1` + belgeli `--tools ""` birlikte araç kullanımını kapatır (`--max-turns` undocumented olduğundan tek başına güvenilmez). Hız + maliyet.
   - Talimat özü: "Yalnız gerçek İngilizce dil hatalarını raporla; metin İngilizce değilse veya hata yoksa boş `mistakes` döndür; üslup önerisi verme."
   - **Watchdog:** macOS'ta GNU `timeout` YOKTUR; yukarıdaki shell-native desen kullanılır. `wait` sonrası sleeper (`wpid`) öldürülür — 30 sn artık süreç ve PID-reuse riski kalmaz. Bilinen sınırlama: 30 sn'yi aşan kontroller fail-open kaybedilir (bilinçli kabul).
6. **Sonuç değerlendirme:** exit code ≠ 0 veya zarfta `is_error:true` (ör. login yok — zarf `subtype:"success"` dönebilir, yanıltıcıdır; ona bakılmaz) → `.result` alanı `last-error.log`'a yazılır ("Not logged in" tek bakışta görünsün), sessiz çıkılır. Başarılıysa `.structured_output.mistakes` içindeki her hata `mistakes.jsonl`'a **satır başına tek `printf '%s\n'` çağrısıyla** append edilir (`>>`, O_APPEND — eşzamanlı iki checker'da interleave olmaz): `{"ts":"<ISO8601>","wrong":"...","right":"...","rule":"..."}`. JSONL satırlarının **üretimi** `osascript -l JavaScript` (`JSON.stringify`) ile yapılır — `plutil` JSON *okur* ama serbest JSON *üretemez*; elle string birleştirmeyle kaçış hatası riski alınmaz.
7. Varsayılan model `claude-haiku-4-5` (hızlı + ucuz — dilbilgisi kontrolü için yeterli); `config.json` yoksa/bozuksa sessizce bu default'a düşülür (config okuma aracı da `plutil`). Çıktı parse edilemezse ham çıktı `last-error.log`'a yazılır (truncate ederek), sessiz çıkılır.
8. Temp dosyalar (`$tmpfile`, `$outfile`) her çıkış yolunda silinir (`trap`).

Tekrar sayısı (`x3`) veri katmanında tutulmaz — app render sırasında aynı `wrong→right` çiftini gruplar. JSONL append-only ve basit kalır.

### 4. Markdown export

Menüden tetiklenir; `mistakes.jsonl`'dan tek tablo üretir (tarih, hata, düzeltme, kural, tekrar) + en sık yapılan 10 hata özeti. Kaydetme yeri `NSSavePanel` ile kullanıcı seçimi (Obsidian vault'una kaydedebilir).

## Veri akışı — uçtan uca

1. Kullanıcı Claude Code'a İngilizce prompt yazar.
2. `UserPromptSubmit` tetiklenir → `hook.sh` payload'ı okur, checker'ı detach eder, exit 0. Oturum gecikme görmez (fd'ler kapalı olduğu için Claude Code beklemez).
3. `checker.sh` guard env'ini kurar, ön-filtreden geçen metni `claude -p`'ye stdin'le verir (arka planda, ~saniyeler). Bu çağrının tetiklediği hook, guard sayesinde ilk satırda çıkar — zincir yok.
4. Hatalar `mistakes.jsonl`'a eklenir.
5. Blooper.app dosya değişikliğini görür → menü tazelenir → bildirim düşer (izin yoksa menübar sayacı).

## Hata yönetimi

- Hook zinciri **her koşulda fail-open**: `claude` yok, login yok, watchdog kill, bozuk JSON — hepsi sessiz çıkış; kullanıcının Claude oturumu asla etkilenmez. Teşhis izi `last-error.log`'da.
- App tarafında: bozuk JSONL satırı atlanır (tek satır listeyi kırmaz), dosya silinir/rename edilirse izleme yeniden kurulur.
- `settings.json`: parse edilemiyorsa dokunulmaz + kullanıcıya hata; her yazımdan önce yedek.
- Kullanıcı app'i hook'u sökmeden çöpe atarsa: hook.sh `Application Support`'ta kaldığı için çalışmaya devam eder; README "Kaldırma" bölümü önce menüden "Remove hook" adımını anlatır. hook.sh kendisi de silinmişse Claude Code hook hatasını sessizce loglar — README'de temizleme komutu verilir.

## Test

- **SPM unit testleri:** JSONL parse (bozuk satır, boş dosya, eksik alan), gruplama/`xN` sayımı, gün bazlı istatistik, settings.json hook ekle/çıkar — fixture'larla: mevcut yabancı hook'lar korunur, `hooks` anahtarı hiç olmayan dosya, **boşluklu yol doğru tırnaklanmış** assert'i.
- **Script testleri (gerçek yol, sahte `claude`):** PATH'e stub `claude` konur (gerçek API çağrısı YOK):
  - normal yapılandırılmış çıktı → JSONL satırları doğru;
  - boş `mistakes` → dosyaya yazım yok;
  - bozuk çıktı → `last-error.log` dolu, JSONL bozulmadı;
  - stub'ın takılması → watchdog öldürür (GNU `timeout` OLMADAN, stok macOS'ta koşan test);
  - **recursion guard (iki yönlü):** `BLOOPER_CHECK=1` ortamında hook.sh anında exit 0; ayrıca miras zinciri gerçek-yolda test edilir — stub `claude`, kendi ortamında `BLOOPER_CHECK=1` gördüğünü assert eder;
  - **eşzamanlılık:** aynı anda iki hook çağrısı → iki bağımsız kontrol, JSONL'de iki doğru satır (mktemp benzersizliği);
  - **detach/gecikme:** hook.sh'ın duvar-saati süresi ölçülür — checker yavaş stub'la bile hook < 1 sn dönmeli;
  - tırnaklı / çok satırlı / emoji'li / 200KB'lık / `'"$(...)"` içerikli prompt fixture'ları — parse ve stdin akışı kırılmaz;
  - Türkçe metin → hiç `claude` çağrısı yok (stub çağrı sayacı 0).
- Edge-case disiplini: testler gerçek üretim yolunu (script'lerin kendisini) çalıştırır; dış servis daima stub.

## Dağıtım

- `scripts/bundle.sh`: `swift build -c release --arch arm64 --arch x86_64` (tek komutta universal binary) → `Blooper.app` (Info.plist, ikon, script'ler `Resources/`e) → **sabit identifier'la ad-hoc codesign** (`codesign -s - --identifier com.barisatalay.blooper`) — denenecek bir hafifletme, garanti değil: ad-hoc imzada TCC kimliği build'den build'e değişen CDHash'e bağlıdır, identifier tek başına stabil kimlik kurmaz. Birincil önlem README'deki "güncellemede bildirim iznini yeniden vermek gerekebilir" notudur.
- `scripts/release.sh`: `bundle.sh` + `hdiutil` ile `.dmg` + `gh release create`.
- **v1 imzasız (Developer ID yok):** README'de Gatekeeper adımları **sürüme göre**: macOS 13/14 → sağ tık → Aç; macOS 15+ → Sistem Ayarları → Gizlilik ve Güvenlik → "Yine de Aç" (yalnız ilk açılışta). Alternatif tek satır: `xattr -d com.apple.quarantine /Applications/Blooper.app`. Developer ID edinilirse notarization `release.sh`'a eklenir.

## Kapsam dışı (v1)

- Claude Code statusline entegrasyonu.
- "Got it / Typo / Ignore" butonları ve hata silme — v2 adayı.
- SwiftBar desteği, Windows/Linux, Claude Code dışındaki kaynaklar.
- Çoklu dil hedefi (yalnız İngilizce kontrol edilir; İngilizce-olmayan girdi sessizce atlanır).

## Bilinen sınırlamalar / riskler

- `claude -p` çağrı maliyeti kullanıcıya aittir; default `claude-haiku-4-5` bunu minimumda tutar, `config.json`'dan daha güçlü model seçilebilir (ör. `claude-sonnet-5` daha isabetli açıklamalar için). README'de açık.
- 30 sn watchdog'u aşan kontroller sessizce kaybedilir (fail-open bilinçli tercihi).
- Claude Code hook şeması ilerde değişirse script güncellenmeli; app sürümüyle script senkronu bu riski hafifletir.
- İmzasız app'lerde bildirim izni diyaloğunun hiç çıkmadığı vakalar raporludur; menübar sayacı bu yüzden bildirimden bağımsız birincil sinyaldir.
- Checker, Claude Code oturumunun process group'unda kalır; kullanıcı Ctrl-C ile oturumu keserse uçuştaki kontrol de ölür (fail-open, kabul edilebilir).
