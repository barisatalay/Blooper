# Blooper Statusline Entegrasyonu — Design Spec (v0.2.0)

**Tarih:** 2026-08-12
**Durum:** Adversarial review tamamlandı (2 tur + nokta-kontrol) — kullanıcı onayı bekliyor
**Temel:** `2026-08-11-blooper-design.md` üzerine eklemedir; oradaki tüm ilkeler (fail-open, macOS-yerleşik araçlar, jq/GNU yasak, izolasyon) aynen geçerli.

## Ne

Claude Code input alanının altında (statusline) o oturumda yakalanan son İngilizce hataları göstermek. Zorluk: `settings.json`'daki `statusLine.command` **tek slottur** ve kullanıcıda N farklı kurulum olabilir (hiç yok / basit komut / plugin script'i / özel script). Çözüm iki parçalı: **fragment** (tek başına anlamlı çıktı birimi) + **wrapper** (mevcut statusline'ı bozmadan saran kabuk).

## Doğrulanmış sözleşme zemini (Claude Code statusline)

- Çok satırlı çıktı desteklenir: her print ayrı satır olarak render edilir.
- Komuta stdin'den JSON payload verilir; `session_id` alanı mevcut ve oturum boyunca stabildir.
- `statusLine` objesi `type`, `command` dışında `padding`, `refreshInterval`, `hideVimModeIndicator` (ve ileride başka) anahtarlar taşıyabilir — **obje daima bütün olarak saklanır/geri yüklenir**.
- Komut shell'de koşar (`"$HOME/..."` genişler); ANSI renk desteklenir.
- Çalıştırma **event-driven**'dır (oturum başı, yeni assistant mesajı, /compact, mod değişimi; 300ms debounce); hard timeout yok ama yeni event uçuştaki script'i iptal eder. `refreshInterval` ile timer eklenebilir.

## Davranış

- Statusline'da **yalnız içinde bulunulan oturumun** hataları görünür (`session_id` eşleşmesi). Payload gelmiş ama `session_id` alanı yoksa VEYA payload hiç yoksa **global moda düşülür** (son-10-dk, oturum filtresi kapalı — iki durum aynı davranış).
- Pencere: son **10 dakika**; üst sınır: **3 satır**; format: `wrong → right · rule` (wrong kırmızı, right yeşil; **her satır `\033[0m` reset ile biter** — statusline satırın sağını sistem bildirimleriyle paylaşır, renk taşmamalı).
- Hata yoksa fragment **hiçbir şey basmaz** (boş satır bile değil).
- Menübar UI'ı değişmez (global kalır).
- **Tazelik:** fragment-only kurulumda `statusLine`'a `"refreshInterval": 20` (birim saniyedir — resmi doc: "re-runs your command every N seconds", min 1) eklenir — hata, assistant cevabından saniyeler sonra geldiği için timer olmadan bir tur gecikmeli görünürdü. **Wrapper kurulumunda:** kullanıcının objesinde `refreshInterval` **yoksa** settings'e yazılan (wrapper'lı) objeye `20` eklenir; kullanıcının **kendi değeri varsa asla dokunulmaz** (kullanıcının kadansı korunur). `config.json`'daki `original_statusline` kaydı her durumda kullanıcının objesinin **birebir aynısıdır** — bizim eklediğimiz `20` oraya sızmaz, uninstall restore'u orijinali aynen geri getirir.

## Veri değişikliği: JSONL şemasına `session`

- `hook.sh` **stdin'i tek kez okuyabilir** — payload önce buffer'lanır: `payload=$(cat)`; sonra iki alan ayrı ayrı `printf '%s' "$payload" | plutil -extract <alan> raw -o - -` ile çıkarılır. `prompt` çıkarımı başarısızsa mevcut davranış (exit 0); `session_id` çıkarımı başarısızsa `session_id=""` (**exit DEĞİL** — session'sız kontrol, oturumsuz kayıttan iyidir).
- checker'a `"$tmpfile" "$session_id"`; checker `session="${2:-}"` alır, JXA üretiminde boş değilse objeye `session` ekler: `{"ts":"...","wrong":"...","right":"...","rule":"...","session":"<id>"}`.
- Swift `Mistake` modeline `let session: String?` — decoder eksik alanı tolere eder, **eski satırlar kırılmaz** (regresyon testi şart). Eski (session'sız) satırlar oturum filtresine takılır ve statusline'da görünmez — bilinçli (menübar'da görünürler).

## Bileşenler

### 1. statusline-fragment.sh (çekirdek birim)

`~/Library/Application Support/Blooper/bin/statusline-fragment.sh` (app, hook/checker gibi senkronlar; `bundle.sh` kopya listesine eklenir):

1. **TTY guard (ilk satır):** `[ -t 0 ] && payload="" || payload=$(cat)` — terminalde elle çalıştıran kullanıcı EOF beklemez, global moda düşer.
2. `session_id`: `session_id=$(printf '%s' "$payload" | plutil -extract session_id raw -o - - 2>/dev/null) || session_id=""` — dikkat: alan yokken plutil hata metnini **stdout'a** (`-o -` hedefine) basar, `2>/dev/null` kozmetiktir; yük taşıyan parça **rc kontrolü + `|| session_id=""`** reset'idir (hata metni değişkende kalmasın).
3. `mistakes.jsonl` yoksa/boşsa sessiz çıkar (exit 0, çıktı yok).
4. **Tek osascript/JXA çağrısıyla** (ölçülmüş maliyet ~22ms): dosyanın **son 200 satırı** parse edilir (daha eskisi taranmaz — Bilinen Sınırlamalar'da), bozuk satır atlanır, `session_id` doluysa `session` eşleşen VE `ts` son 10 dk içindeki kayıtlar süzülür (`session_id` boşsa yalnız ts filtresi), son 3'ü ANSI'li formatta basılır, her satır `\033[0m` ile biter.
5. Her hata yolu fail-open: exit 0 + boş çıktı.

Manuel entegrasyon (README): kendi script'i olan kullanıcı sonuna `printf '%s' "$payload" | "$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh"` ekler (payload değişkeni yoksa payload'sız çağrı da güvenli — TTY-dışı boş stdin anında EOF döner, global moda düşer).

### 2. blooper-statusline.sh (wrapper — kurulumda üretilir)

App, kurulum anında üretir (`bin/blooper-statusline.sh`). **Orijinal komut ham gömülmez** — çok satırlı / `;`/`&&`'li / `#`'li komutlar ham şablonu bozar (pipe `&&`'dan sıkı bağlanır → payload yalnız ilk komuta gider; çok satır yorum bloğundan taşar). Doğrusu: Swift üretimi orijinali **tek güvenli kaçışla** (`'` → `'\''`) tek-tırnaklı değişkene koyar:

```bash
#!/bin/bash
# BLOOPER-STATUSLINE-WRAPPER v1 — kaldırmak için Blooper menüsünü kullanın.
# Orijinal statusline BLOOPER_ORIGINAL değişkenindedir; restore kaynağı config.json'dur (bu dosya değil).
BLOOPER_ORIGINAL='<escaped-original-command>'
FRAGMENT="$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh"
[ -t 0 ] && payload="" || payload=$(cat)   # TTY guard: elle çalıştıran EOF beklemesin
# Orijinal alt shell'de koşar: çok satır, ;, &&, # ve quoting tek hamlede güvenli.
# Çıktı yakalanıp printf '%s\n' ile normalize edilir: orijinal sona newline basmazsa
# fragment'ın ilk satırı ona yapışırdı ("her satır = bir row" newline'a dayanır).
out=$(printf '%s' "$payload" | /bin/bash -c "$BLOOPER_ORIGINAL" 2>/dev/null)
[ -n "$out" ] && printf '%s\n' "$out"
[ -x "$FRAGMENT" ] && printf '%s' "$payload" | "$FRAGMENT"
exit 0
```

- Payload iki tüketiciye de verilir; orijinalin exit code'u yutulur (fail-open: patlarsa yalnız fragment görünür — kullanıcı statusline'ının değiştiğini fark edip README'deki nota ulaşır).
- **Tek hakikat kaynağı restore için `config.json`'daki `original_statusline` objesidir** (yorum bloğu/değişken objenin `padding`/`refreshInterval` gibi anahtarlarını taşıyamaz; wrapper içi yalnız insan-okur bilgidir ve bu, dosya başında açıkça yazar).
- Marker sürümlüdür (`v1`): Install, marker **sürümü farklıysa** wrapper'ı güncel şablonla yeniden üretir (aynı sürümse no-op).

### 3. StatuslineInstaller.swift

`HookInstaller` ile aynı disiplin (settings backup, parse edilemeyene dokunmama, idempotency):

- **"Bizim" sınıflandırması (kritik):** komut string'i, bizim ürettiğimiz komuta (fragment veya wrapper çağrısı) **trim sonrası birebir EŞİTSE** bizimdir. Yolu *içeren ama eşit olmayan* komut (kullanıcı fragment'ı kendi pipeline'ına gömmüş olabilir) **yabancıdır** — substring eşleşmesi KULLANILMAZ; aksi halde Remove, kullanıcının kendi zincirini siler/ezerdi.
- **Kur:**
  - `statusLine` yoksa → `{"type":"command","command":"\"$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh\"","refreshInterval":20}` (boşluklu yol çift-tırnaklı `$HOME` — hook komutuyla aynı desen).
  - Komut bizimse (birebir eşit) → wrapper durumunda marker sürümü aynıysa no-op, farklıysa wrapper yeniden üretilir; fragment durumunda no-op (fragment'ta sürüm kavramı yok).
  - **Çift-sarma koruması (best-effort dosya-içi tarama):** komut string'inden hedef script dosyası çıkarılmaya çalışılır — baştaki interpreter token'ları (`bash`/`sh`/`zsh`) soyulur, tırnaklar çözülür, `$HOME`/`~` genişletilir; kalan ilk argüman mevcut bir dosyaysa okunup içinde `BLOOPER-STATUSLINE-WRAPPER` aranır. Bulunursa kurulum reddedilir + "statusline zaten Blooper içeriyor; önce elle çözün" hatası. Dosya çıkarılamıyorsa (ör. `bash -c '<inline>'`) tarama atlanır — birincil koruma yukarıdaki tam-eşleşme sınıflandırmasıdır, bu tarama ek katmandır.
  - Yabancıysa → orijinal `statusLine` **objesi bütün olarak** `config.json`'a `original_statusline` anahtarıyla kaydedilir + wrapper üretilir + `statusLine.command` wrapper yoluna çevrilir (objenin diğer anahtarları settings'te aynen korunur). Objede `refreshInterval` yoksa settings'teki wrapper'lı objeye `20` eklenir (config'teki orijinal kayda değil).
- **Kaldır:**
  - Komut bizim fragment komutuna eşitse → `statusLine` anahtarı silinir (kurulum öncesi "yok" durumu).
  - Komut bizim wrapper komutuna eşitse → `original_statusline` objesi settings'e geri yazılır, config'ten silinir, wrapper dosyası silinir. **`original_statusline` config'te yoksa/bozuksa (elle silinmiş olabilir):** `statusLine` anahtarı silinir (fragment-dalı davranışına düşülür) + wrapper dosyası silinir + kullanıcıya "orijinal statusline kaydı bulunamadı; gerekirse `settings.json.blooper-backup`'tan geri alabilirsin" mesajı gösterilir.
  - Yabancıysa → settings'e **dokunulmaz**; ama `original_statusline` config'te duruyorsa kullanıcıya **açıklayıcı mesaj** gösterilir ("statusline başka bir araçça değiştirilmiş; orijinalin `config.json`'da saklı, Blooper parçalarını elle kaldırabilirsin") + wrapper dosyasını silme teklif edilir. Sessiz no-op YOK.
  - Remove idempotent'tir (ikinci Remove hata üretmez).
- **config.json disiplini:** güncelleme daima **read-modify-write**'tır — `model`, `notifications` ve bilinmeyen anahtarlar korunur; parse edilemeyen config.json'a dokunulmaz + hata gösterilir (settings.json disiplininin eşleniği).

### 4. UI

MenuView'a hook toggle'ının yanına: **"Install statusline" / "Remove statusline"** — aynı hata gösterim deseni. Buton altına küçük not: değişiklik **bir sonraki etkileşimde** görünür (statusline anında yenilenmez). Buton durumu `StatuslineInstaller.isInstalled()`.

## Bilinen sınırlamalar (bilinçli kabuller)

- **Bayat-orijinal:** wrapper kuruluyken kullanıcı statusline'ını değiştirirse settings hâlâ wrapper'ı gösterir. README: "statusline değiştirdiysen Remove + Install".
- **Wrapper kurulumunda tazelik (kısmi):** kullanıcının objesinde `refreshInterval` yoksa `20` eklenir ve hatalar timer'la görünür hale gelir; kullanıcının **kendi** `refreshInterval` değeri varsa ona dokunulmaz — değer büyükse hata o kadansta (en geç bir sonraki event'te) görünür.
- Fragment yalnız son 200 JSONL satırını tarar (çok yoğun kullanımda daha eski ama taze kayıt teorik olarak atlanabilir).
- Eski (session'sız) satırlar statusline'da görünmez.
- 10 dk / 3 satır sabittir (config'e bağlanmaz — YAGNI).
- Çok satırlı + ANSI'li statusline'lar, düz tek satıra göre render sorunlarına daha yatkındır (resmi doc uyarısı).
- Wrapper'daki `out=$(...)` yakalaması, orijinal çıktının **sondaki boş satırlarını** düşürür (içteki boş satırlar korunur) — boş satırla yükseklik ayarlayan statusline'larda görünür fark olabilir.
- Fragment-only kurulum Claude Code'un varsayılan footer ipuçlarını (kısayol hatırlatmaları) gizler — README/onboarding notu.
- Proje-seviyesi `.claude/settings.json` statusline tanımlıyorsa o projede Blooper statusline'ı görünmez (user-level ezilir) — README notu.

## Test

- **Script (run.sh'a eklenir, stub'lı, gerçek üretim yolu):**
  - fragment: eşleşen oturum + taze ts → basar; başka oturum → basmaz; eski ts → basmaz; 5 kayıt → son 3; dosya yok/boş/bozuk satır → boş çıktı exit 0; **payload var ama `session_id` alanı yok → global davranış**; payload'sız (kapalı stdin) → global; her çıktı satırı `\033[0m` ile bitiyor; **>200 satırlık dosyada tail-dışı kayıt basılmıyor** (belgelenmiş sınır).
  - wrapper: payload'ı echo'layan sahte orijinal → önce orijinal satırı sonra fragment satırları; **orijinal `printf`-tarzı newline'sız** → satırlar yapışmıyor; **orijinal `;`/`&&` içeriyor** → komut grubu payload pipe'ını **native semantikle paylaşıyor** (her parça payload'ın tamamını GÖREMEZ — stdin tek'tir, parçalar sırayla tüketir; bu `bash -c` sarmasının doğru davranışıdır, "hepsine tam kopya" assert'i yazılamaz); orijinal exit 1 → fragment yine basılır, wrapper exit 0; orijinal çok satırlı ve `'` içeren string → wrapper geçerli üretiliyor ve çalışıyor.
  - hook: `payload=$(cat)` sonrası **prompt tam ulaşıyor** (200KB testi session'lı payload varyantıyla); `session_id` JSONL satırına yazılıyor; payload'da `session_id` yokken alansız satır + prompt yine kontrol ediliyor.
- **Swift:**
  - `Mistake`: session'lı ve session'sız (eski format) satırlar parse edilir.
  - `StatuslineInstaller`: yok→fragment+refreshInterval kur; yabancı→wrapper + orijinal obje (**`padding`, `refreshInterval`, `hideVimModeIndicator` ve bilinmeyen rastgele anahtar dahil**) config'e kaydedilir ve kaldırınca **birebir** geri gelir; bizimki→idempotent; marker sürüm farkı→yeniden üretim; Remove→Remove idempotent; Install→Install→Remove sırası; **fragment yolunu içeren-ama-eşit-olmayan komut yabancı sayılır** (Remove dokunmaz, mesaj gösterir); **wrapper'a eşit komut + config'te `original_statusline` yok → fallback (anahtar silinir + wrapper silinir + mesaj)**; parse edilemeyen settings/config→throw + dosyaya dokunulmaz; config RMW'de `model`/`notifications` korunur; çift-sarma dosya-içi taramayla reddedilir.
- Gerçek-ortam smoke: ponytail statusline'ı sarılır → ponytail çıktısı + altında hata satırları; Remove → ponytail objesi birebir geri.

## Sürüm / dağıtım

v0.2.0. `bundle.sh` kopya listesine `statusline-fragment.sh` eklenir (wrapper kurulumda üretilir, bundle'a girmez). README'ye "Statusline" bölümü: kur/kaldır, bayat-orijinal notu, manuel entegrasyon tarifi, footer-ipuçları ve proje-seviyesi-settings notları.
