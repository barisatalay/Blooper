# Blooper Statusline Entegrasyonu Implementation Plan (v0.2.0)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code statusline'ında o oturumun son İngilizce hatalarını göstermek — kullanıcının mevcut statusline'ı ne olursa olsun bozmadan.

**Architecture:** JSONL'e opsiyonel `session` alanı eklenir (hook → checker); `statusline-fragment.sh` oturum-bazlı son-10-dk hataları basar; kurulumda üretilen wrapper mevcut statusline'ı sarar; `StatuslineInstaller` settings/config'i güvenli yönetir. Spec: `docs/superpowers/specs/2026-08-12-statusline-design.md` — bağlayıcı; oradaki tüm desenler (tam-eşleşme sınıflandırma, TTY guard, tek-tırnak kaçışı, RMW) empirik doğrulanmıştır.

**Tech Stack:** bash + plutil + osascript/JXA (ObjC köprüsüyle dosya okuma), Swift (StatuslineInstaller, SwiftUI buton), XCTest, mevcut `tests/scripts/run.sh` altyapısı.

## Global Constraints

- v0.1 Global Constraints aynen geçerli (fail-open, jq/GNU yasak, macOS-yerleşik araçlar, boşluklu yol tırnaklı, gerçek `claude` testte yasak, yorumlar Türkçe, commit İngilizce conventional).
- "Bizim statusline" tespiti **trim sonrası birebir eşitlik** — substring ASLA.
- Wrapper üretiminde orijinal komut kaçışı: `'` → `'\''`, başka hiçbir karakter değişmez.
- Fragment/wrapper her hata yolunda exit 0 + (fragment'ta) boş çıktı.
- `refreshInterval` birimi **saniye**; yalnız fragment-only kurulumda `30` yazılır.
- `config.json` güncellemeleri read-modify-write: `model`/`notifications`/bilinmeyen anahtarlar korunur.
- Wrapper şablonu tek kaynak: `Resources/scripts/statusline-wrapper-template.sh` (placeholder `__BLOOPER_ORIGINAL__`) — Swift de bash testleri de aynı şablonu kullanır.

## Dosya Haritası

```
Resources/scripts/hook.sh                        — değişir: payload buffer + session_id
Resources/scripts/checker.sh                     — değişir: $2=session, JXA'ya geçer
Resources/scripts/statusline-fragment.sh         — yeni
Resources/scripts/statusline-wrapper-template.sh — yeni (placeholder'lı şablon)
Sources/Blooper/Model/Mistake.swift              — değişir: session: String?
Sources/Blooper/Model/StatuslineInstaller.swift  — yeni
Sources/Blooper/Environment.swift                — değişir: sync listesine fragment
Sources/Blooper/Views/MenuView.swift             — değişir: statusline butonu
Tests/BlooperTests/StatuslineInstallerTests.swift— yeni
Tests/BlooperTests/MistakeTests.swift            — değişir: session testleri
tests/scripts/run.sh                             — değişir: fragment/wrapper/session testleri
scripts/bundle.sh                                — değişir: kopya listesi
README.md                                        — değişir: Statusline bölümü
```

---

### Task 1: JSONL'e session alanı (hook.sh + checker.sh)

**Files:**
- Modify: `Resources/scripts/hook.sh`, `Resources/scripts/checker.sh`
- Modify: `tests/scripts/run.sh` (yeni testler + mevcutların uyumu)

**Interfaces:**
- Produces: hook → checker çağrısı `checker.sh "$tmpfile" "$session_id"`; JSONL satırı (session'lıyken) `{"ts","wrong","right","rule","session"}`. Task 2 (Mistake) ve Task 3 (fragment) bu şemayı okur.

- [ ] **Step 1: hook.sh'ı güncelle** — plutil satırlarını şu blokla değiştir:

```bash
# stdin TEK KEZ okunabilir: payload buffer'lanır, alanlar ondan ayrı ayrı çıkarılır
payload=$(cat)
prompt=$(printf '%s' "$payload" | plutil -extract prompt raw -o - - 2>/dev/null) || exit 0
[ -z "$prompt" ] && exit 0
# session_id yoksa plutil hata metnini STDOUT'a basar (rc=1) — || reset'i yük taşıyan parçadır
session_id=$(printf '%s' "$payload" | plutil -extract session_id raw -o - - 2>/dev/null) || session_id=""
```

ve checker çağrısını `"$CHECKER" "$tmpfile" "$session_id" </dev/null >/dev/null 2>&1 &` yap.

- [ ] **Step 2: checker.sh'ı güncelle** — `tmpfile="${1:-}"` altına `session="${2:-}"`; JXA çağrısına 3. argüman olarak `"$session"` ekle ve JS'i şöyle değiştir:

```javascript
function run(argv) {
    const arr = JSON.parse(argv[0]);
    const ts = argv[1];
    const session = argv[2];
    return arr.map(m => {
        const o = {ts: ts, wrong: m.wrong, right: m.right, rule: m.rule};
        if (session) o.session = session;
        return JSON.stringify(o);
    }).join("\n");
}
```

(Shell tarafında: `... "$mistakes" "$ts" "$session" 2>>"$LOG" | while ...`)

- [ ] **Step 3: run.sh testlerini ekle/güncelle**

Mevcut `hook_payload` zaten `session_id:"s"` gönderiyor. `run_checker`'a opsiyonel 2. argüman ekle: `"$BLOOPER_SUPPORT_DIR/bin/checker.sh" "$tf" "${2:-}"`. Yeni testler:

```bash
test_checker_session_in_jsonl() {
    setup_env; checker_fixture_ok
    run_checker "I am agree with you post here" "sess-abc"
    line=$(tail -1 "$BLOOPER_SUPPORT_DIR/mistakes.jsonl")
    sess=$(printf '%s' "$line" | plutil -extract session raw -o - - 2>/dev/null) || sess=""
    [ "$sess" = "sess-abc" ] || { fail "session yazılmadı: $line"; return; }
    pass "checker writes session field"
}

test_checker_no_session_no_field() {
    setup_env; checker_fixture_ok
    run_checker "I am agree with you post here" ""
    line=$(tail -1 "$BLOOPER_SUPPORT_DIR/mistakes.jsonl")
    printf '%s' "$line" | plutil -extract session raw -o - - >/dev/null 2>&1 && { fail "boş session'da alan yazıldı"; return; }
    printf '%s' "$line" | plutil -extract wrong raw -o - - >/dev/null 2>&1 || { fail "satır geçersiz"; return; }
    pass "checker omits empty session"
}

test_hook_passes_session_to_checker() {
    setup_env
    printf '#!/bin/bash\nprintf "ARG2:%%s\\n" "$2" >> "%s"\n' "$STUB_LOG" > "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    chmod +x "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    printf '{"session_id":"sess-xyz","prompt":"I am agree with you"}' | "$BLOOPER_SUPPORT_DIR/bin/hook.sh"
    sleep 1
    grep -q 'ARG2:sess-xyz' "$STUB_LOG" || { fail "session hook'tan geçmedi"; return; }
    pass "hook passes session_id"
}

test_hook_missing_session_still_checks() {
    setup_env
    printf '#!/bin/bash\nprintf "ARG2:[%%s]\\n" "$2" >> "%s"\n' "$STUB_LOG" > "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    chmod +x "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    printf '{"prompt":"I am agree with you here"}' | "$BLOOPER_SUPPORT_DIR/bin/hook.sh"
    sleep 1
    grep -q 'ARG2:\[\]' "$STUB_LOG" || { fail "session'sız payload'da checker koşmadı/arg bozuk"; return; }
    pass "hook tolerates missing session_id"
}
```

Çağrı listesine dördünü ekle.

- [ ] **Step 4: Koş** — `tests/scripts/run.sh` → tümü pass (19 test). Mevcut testler kırılmamalı (özellikle 200KB ve tricky-prompt — payload buffer'lamanın regresyon kilidi).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: record session id in mistake log"`

---

### Task 2: Mistake.session (Swift)

**Files:**
- Modify: `Sources/Blooper/Model/Mistake.swift`, `Tests/BlooperTests/MistakeTests.swift`

**Interfaces:**
- Produces: `Mistake.session: String?` — Task 5'in fixture'ları ve menübar (değişmeden) kullanır.

- [ ] **Step 1: Testleri ekle** (MistakeTests.swift'e):

```swift
    func testParsesLineWithSession() throws {
        let line = #"{"ts":"2026-08-12T10:00:00Z","wrong":"a","right":"b","rule":"c","session":"s-1"}"#
        let m = try XCTUnwrap(Mistake.parse(line: line))
        XCTAssertEqual(m.session, "s-1")
    }

    func testParsesLegacyLineWithoutSession() throws {
        let line = #"{"ts":"2026-08-12T10:00:00Z","wrong":"a","right":"b","rule":"c"}"#
        let m = try XCTUnwrap(Mistake.parse(line: line))
        XCTAssertNil(m.session)
    }
```

- [ ] **Step 2: FAIL gör** — `swift test --filter MistakeTests` → derleme hatası (session yok).

- [ ] **Step 3: Modeli güncelle** — `Mistake`'e `let session: String?` ekle. Mevcut testlerdeki/`MistakeLogTests`'teki `Mistake(ts:wrong:right:rule:)` çağrıları için memberwise init kırılır — struct'a açık init EKLEME; bunun yerine mevcut test çağrılarına `, session: nil` ekle (tek sed geçişi) ya da default'lu init yaz:

```swift
    init(ts: Date, wrong: String, right: String, rule: String, session: String? = nil) {
        self.ts = ts; self.wrong = wrong; self.right = right; self.rule = rule; self.session = session
    }
```

(Default'lu init tercih edilir — çağrılar değişmez; Codable senteziyle çakışmaz.)

- [ ] **Step 4: PASS** — `swift test` tam takım yeşil (22 test).

- [ ] **Step 5: Commit** — `git commit -am "feat: add optional session to mistake model"`

---

### Task 3: statusline-fragment.sh

**Files:**
- Create: `Resources/scripts/statusline-fragment.sh`
- Modify: `tests/scripts/run.sh`

**Interfaces:**
- Consumes: `mistakes.jsonl` (Task 1 şeması), stdin'den statusline payload'ı (`session_id`).
- Produces: stdout'a ≤3 satır `wrong → right · rule` (ANSI, her satır `\033[0m` ile biter) veya hiçbir şey. Task 4 wrapper'ı ve Task 5 installer'ı bu dosya yoluna bağlanır.

- [ ] **Step 1: Script'i yaz**

```bash
#!/bin/bash
# Statusline parçası: bu oturumda son 10 dakikada yakalanan hatalar (en fazla 3 satır).
# Her hata yolu fail-open: exit 0 + boş çıktı — statusline asla bozulmaz.
SUPPORT_DIR="${BLOOPER_SUPPORT_DIR:-$HOME/Library/Application Support/Blooper}"
FILE="$SUPPORT_DIR/mistakes.jsonl"

# TTY guard: terminalde elle çalıştıran EOF beklemesin (global moda düşer)
[ -t 0 ] && payload="" || payload=$(cat)
# session_id yoksa plutil hata metnini STDOUT'a basar — || reset'i şart
session_id=$(printf '%s' "$payload" | plutil -extract session_id raw -o - - 2>/dev/null) || session_id=""

[ -s "$FILE" ] || exit 0
now=$(date -u +%s)

res=$(osascript -l JavaScript -e '
function run(argv) {
    ObjC.import("Foundation");
    const raw = $.NSString.stringWithContentsOfFileEncodingError($(argv[0]), $.NSUTF8StringEncoding, null);
    const content = ObjC.unwrap(raw);   // nil → undefined (JXA nil-wrapper "!raw" ile yakalanmaz)
    if (!content) return "";
    const session = argv[1];
    const now = parseInt(argv[2], 10);
    // yalnız son 200 satır taranır (belgelenmiş sınır)
    const lines = content.split("\n").slice(-200);
    const hits = [];
    for (const line of lines) {
        if (!line) continue;
        let m; try { m = JSON.parse(line); } catch (e) { continue; }
        if (!m.ts || !m.wrong || !m.right) continue;
        const t = Date.parse(m.ts) / 1000;
        if (isNaN(t) || now - t > 600) continue;          // 10 dk penceresi
        if (session && m.session !== session) continue;    // oturum filtresi (boşsa global)
        hits.push(m);
    }
    const E = "\u001b";   // ESC — \u kacisiyla, gorunmez bayt gommeden
    const R = E + "[0m";
    return hits.slice(-3).map(m =>
        E + "[31m" + m.wrong + R + " \u2192 " + E + "[32m" + m.right + R + " \u00b7 " + (m.rule || "") + R
    ).join("\n");

[ -n "$res" ] && printf '%s\n' "$res"
exit 0
```

`chmod +x Resources/scripts/statusline-fragment.sh`

- [ ] **Step 2: Testleri ekle** (run.sh — setup_env kopya listesi `statusline-fragment.sh`'ı da alacak şekilde `cp` satırı güncellenir):

```bash
sl_payload() { printf '{"session_id":%s,"model":{"id":"m"}}' "$1"; }

write_mistake() { # $1=epoch-offset-sn $2=session(veya boş) $3=wrong
    ts=$(date -u -v-"$1"S +%Y-%m-%dT%H:%M:%SZ)
    if [ -n "$2" ]; then
        printf '{"ts":"%s","wrong":"%s","right":"fixed","rule":"r","session":"%s"}\n' "$ts" "$3" "$2"
    else
        printf '{"ts":"%s","wrong":"%s","right":"fixed","rule":"r"}\n' "$ts" "$3"
    fi >> "$BLOOPER_SUPPORT_DIR/mistakes.jsonl"
}

FRAG() { "$BLOOPER_SUPPORT_DIR/bin/statusline-fragment.sh"; }

test_fragment_matching_session_fresh() {
    setup_env
    write_mistake 60 "s1" "I am agree"
    out=$(sl_payload '"s1"' | FRAG)
    case "$out" in *"I am agree"*) pass "fragment shows matching fresh" ;; *) fail "fragment boş: [$out]" ;; esac
}

test_fragment_other_session_hidden() {
    setup_env
    write_mistake 60 "s1" "I am agree"
    out=$(sl_payload '"s2"' | FRAG)
    [ -z "$out" ] || { fail "başka oturum sızdı: $out"; return; }
    pass "fragment hides other session"
}

test_fragment_stale_hidden() {
    setup_env
    write_mistake 700 "s1" "old mistake"
    out=$(sl_payload '"s1"' | FRAG)
    [ -z "$out" ] || { fail "bayat kayıt sızdı: $out"; return; }
    pass "fragment hides stale (>10min)"
}

test_fragment_caps_at_three() {
    setup_env
    for i in 1 2 3 4 5; do write_mistake 60 "s1" "wrong$i"; done
    out=$(sl_payload '"s1"' | FRAG)
    n=$(printf '%s\n' "$out" | grep -c 'fixed')
    [ "$n" -eq 3 ] || { fail "satır sayısı $n (3 bekleniyordu)"; return; }
    case "$out" in *wrong5*) : ;; *) fail "en yeni kayıt yok"; return ;; esac
    case "$out" in *wrong1*|*wrong2*) fail "eski kayıtlar elenmedi"; return ;; esac
    pass "fragment caps at last 3"
}

test_fragment_no_session_field_global() {
    setup_env
    write_mistake 60 "s1" "I am agree"
    out=$(printf '{"model":{"id":"m"}}' | FRAG)     # payload var, session_id alanı yok
    case "$out" in *"I am agree"*) pass "fragment global fallback (no session_id)" ;; *) fail "global düşüş çalışmadı" ;; esac
}

test_fragment_empty_and_garbage() {
    setup_env
    out=$(sl_payload '"s1"' | FRAG); [ -z "$out" ] || { fail "boş dosyada çıktı"; return; }
    printf 'garbage line\n{"ts":"broken"}\n' >> "$BLOOPER_SUPPORT_DIR/mistakes.jsonl"
    write_mistake 60 "s1" "I am agree"
    out=$(sl_payload '"s1"' | FRAG)
    case "$out" in *"I am agree"*) pass "fragment skips garbage lines" ;; *) fail "bozuk satır taramayı kırdı" ;; esac
}

test_fragment_ansi_reset_per_line() {
    setup_env
    write_mistake 60 "s1" "I am agree"; write_mistake 30 "s1" "teh"
    sl_payload '"s1"' | FRAG | while IFS= read -r line; do
        case "$line" in *$'\033[0m') : ;; *) fail "satır reset ile bitmiyor: $line"; exit 1 ;; esac
    done || return
    pass "fragment lines end with ANSI reset"
}

test_fragment_tail_200_limit() {
    setup_env
    write_mistake 60 "s1" "buried"                 # eşleşen kayıt en başta
    i=0; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    while [ $i -lt 210 ]; do printf '{"ts":"%s","wrong":"pad","right":"p","rule":"r","session":"zzz"}\n' "$ts"; i=$((i+1)); done >> "$BLOOPER_SUPPORT_DIR/mistakes.jsonl"
    out=$(sl_payload '"s1"' | FRAG)
    [ -z "$out" ] || { fail "tail-200 sınırı delindi"; return; }
    pass "fragment scans only last 200 lines (documented limit)"
}
```

Çağrı listesine sekizini ekle.

- [ ] **Step 3: Koş** — `tests/scripts/run.sh` → tümü pass.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: add session-scoped statusline fragment"`

---

### Task 4: Wrapper şablonu

**Files:**
- Create: `Resources/scripts/statusline-wrapper-template.sh`
- Modify: `tests/scripts/run.sh`

**Interfaces:**
- Produces: placeholder'lı şablon; Task 5'te Swift `__BLOOPER_ORIGINAL__`'ı kaçışlı orijinalle değiştirir. Bash testleri aynı substitusyonu perl'le yapar (tek kaynak).

- [ ] **Step 1: Şablonu yaz**

```bash
#!/bin/bash
# BLOOPER-STATUSLINE-WRAPPER v1 — kaldırmak için Blooper menüsünü kullanın.
# Orijinal statusline BLOOPER_ORIGINAL değişkenindedir; restore kaynağı config.json'dur (bu dosya değil).
BLOOPER_ORIGINAL='__BLOOPER_ORIGINAL__'
FRAGMENT="$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh"
# TTY guard: elle çalıştıran EOF beklemesin
[ -t 0 ] && payload="" || payload=$(cat)
# Orijinal alt shell'de koşar (çok satır, ;, &&, # ve quoting güvenli); çıktı newline-normalize
# edilir — orijinal sona newline basmazsa fragment ilk satırına yapışırdı.
out=$(printf '%s' "$payload" | /bin/bash -c "$BLOOPER_ORIGINAL" 2>/dev/null)
[ -n "$out" ] && printf '%s\n' "$out"
[ -x "$FRAGMENT" ] && printf '%s' "$payload" | "$FRAGMENT"
exit 0
```

- [ ] **Step 2: Test yardımcısı + testler** (run.sh):

```bash
make_wrapper() { # $1 = orijinal komut; üretilen wrapper yolunu basar
    # Substitüsyon satır-birleştirmeyle yapılır (sed/perl replacement'ta özel karakter tuzağı yok):
    # placeholder satırı atılır, yerine kaçışlı orijinali taşıyan atama satırı yazılır.
    esc=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")     # ' → '\''  (satır İÇİ kaçış; çok satırlı orijinal
    # sed satır satır işlediği için newline'lar korunur — atama satırına printf '%s' ile gömülür)
    t="$ROOT/Resources/scripts/statusline-wrapper-template.sh"
    w="$BLOOPER_SUPPORT_DIR/bin/blooper-statusline.sh"
    n=$(grep -n '__BLOOPER_ORIGINAL__' "$t" | cut -d: -f1)
    head -n $((n-1)) "$t" > "$w"
    { printf "BLOOPER_ORIGINAL='"; printf '%s' "$esc"; printf "'\n"; } >> "$w"
    tail -n +$((n+1)) "$t" >> "$w"
    chmod +x "$w"; printf '%s' "$w"
}

test_wrapper_original_then_fragment() {
    setup_env
    write_mistake 60 "s1" "I am agree"
    w=$(make_wrapper 'printf "ORIGINAL-LINE\n"')
    out=$(sl_payload '"s1"' | "$w")
    first=$(printf '%s\n' "$out" | head -1)
    [ "$first" = "ORIGINAL-LINE" ] || { fail "orijinal önce değil: $first"; return; }
    case "$out" in *"I am agree"*) pass "wrapper: original then fragment" ;; *) fail "fragment eklenmedi" ;; esac
}

test_wrapper_no_trailing_newline_original() {
    setup_env
    write_mistake 60 "s1" "I am agree"
    w=$(make_wrapper 'printf "NO-NEWLINE"')
    out=$(sl_payload '"s1"' | "$w")
    first=$(printf '%s\n' "$out" | head -1)
    [ "$first" = "NO-NEWLINE" ] || { fail "satır yapıştı: $first"; return; }
    pass "wrapper normalizes missing newline"
}

test_wrapper_multiline_and_quote_original() {
    setup_env
    w=$(make_wrapper 'echo "it'"'"'s line1"
echo line2')
    out=$(printf '{"session_id":"s1"}' | "$w"); rc=$?
    [ "$rc" -eq 0 ] || { fail "çok satırlı orijinal rc=$rc"; return; }
    case "$out" in *"it's line1"*line2*) pass "wrapper survives multiline+quote original" ;; *) fail "çıktı: $out" ;; esac
}

test_wrapper_failing_original_failopen() {
    setup_env
    write_mistake 60 "s1" "I am agree"
    w=$(make_wrapper 'exit 7')
    out=$(sl_payload '"s1"' | "$w"); rc=$?
    [ "$rc" -eq 0 ] || { fail "wrapper rc=$rc"; return; }
    case "$out" in *"I am agree"*) pass "wrapper fail-open on broken original" ;; *) fail "fragment kayıp"; esac
}

test_wrapper_group_shares_stdin_native() {
    setup_env
    # ; ile ayrılan grup stdin'i NATIVE semantikle paylaşır: ilk komut 5 bayt alır, ikincisi kalanı görür
    w=$(make_wrapper 'head -c 5 >/dev/null; wc -c | tr -d " "')
    out=$(printf '{"session_id":"s1"}' | "$w")
    first=$(printf '%s\n' "$out" | head -1)
    total=$(printf '{"session_id":"s1"}' | wc -c | tr -d ' ')
    [ "$first" = "$((total - 5))" ] || { fail "grup stdin paylaşımı beklenen değil: $first"; return; }
    pass "wrapper group shares payload pipe natively"
}
```

Çağrı listesine beşini ekle. (make_wrapper'daki perl yolu birincil; fallback dal, perl `\Q` sınırına takılırsa satır-bazlı birleştirme yapar — test her iki yolda da aynı wrapper'ı üretir.)

- [ ] **Step 3: Koş** — `tests/scripts/run.sh` → tümü pass.

- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat: add statusline wrapper template with safe original embedding"`

---

### Task 5: StatuslineInstaller (Swift, TDD)

**Files:**
- Create: `Sources/Blooper/Model/StatuslineInstaller.swift`, `Tests/BlooperTests/StatuslineInstallerTests.swift`

**Interfaces:**
- Consumes: şablon (Task 4), settings/config JSON dosyaları.
- Produces: `struct StatuslineInstaller { init(settingsURL:configURL:binDir:templateURL:); func isInstalled() -> Bool; @discardableResult func install() throws -> String?; @discardableResult func uninstall() throws -> String? }` — dönen `String?` kullanıcıya gösterilecek bilgi mesajı (nil = sessiz başarı). `enum StatuslineError: Error { case unparsableSettings, unparsableConfig, alreadyContainsBlooper, templateMissing }`. Task 6 UI bunu çağırır.

- [ ] **Step 1: Testleri yaz**

```swift
import XCTest
@testable import Blooper

final class StatuslineInstallerTests: XCTestCase {
    var dir: URL!
    var installer: StatuslineInstaller!
    var settings: URL { dir.appendingPathComponent("settings.json") }
    var config: URL { dir.appendingPathComponent("config.json") }
    var binDir: URL { dir.appendingPathComponent("bin") }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        // Şablon repo'dan okunur: test, gerçek üretim şablonunu kullanır
        let template = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/scripts/statusline-wrapper-template.sh")
        installer = StatuslineInstaller(settingsURL: settings, configURL: config, binDir: binDir, templateURL: template)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ url: URL, _ json: String) throws { try json.write(to: url, atomically: true, encoding: .utf8) }
    private func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    private func statusLine() throws -> [String: Any]? { try readJSON(settings)["statusLine"] as? [String: Any] }

    func testInstallIntoMissingStatusline() throws {
        try write(settings, "{}")
        XCTAssertNil(try installer.install())
        let sl = try XCTUnwrap(try statusLine())
        XCTAssertEqual(sl["type"] as? String, "command")
        XCTAssertTrue((sl["command"] as? String ?? "").contains("statusline-fragment.sh"))
        XCTAssertEqual(sl["refreshInterval"] as? Int, 30)
        XCTAssertTrue(installer.isInstalled())
    }

    func testInstallWrapsForeignAndUninstallRestoresExactly() throws {
        let original: [String: Any] = ["type": "command", "command": "my-status --flag",
                                       "padding": 0, "refreshInterval": 5, "customKey": "x"]
        try write(settings, String(data: JSONSerialization.data(withJSONObject: ["statusLine": original]), encoding: .utf8)!)
        try write(config, #"{"model":"claude-haiku-4-5","notifications":true}"#)
        XCTAssertNil(try installer.install())
        let sl = try XCTUnwrap(try statusLine())
        XCTAssertTrue((sl["command"] as? String ?? "").contains("blooper-statusline.sh"))
        XCTAssertEqual(sl["padding"] as? Int, 0, "diğer anahtarlar settings'te korunur")
        // wrapper dosyası üretildi + orijinal komut kaçışlı gömüldü
        let wrapper = try String(contentsOf: binDir.appendingPathComponent("blooper-statusline.sh"), encoding: .utf8)
        XCTAssertTrue(wrapper.contains("my-status --flag"))
        XCTAssertFalse(wrapper.contains("__BLOOPER_ORIGINAL__"))
        // config: RMW — mevcut anahtarlar korunur + original_statusline eklendi
        let cfg = try readJSON(config)
        XCTAssertEqual(cfg["model"] as? String, "claude-haiku-4-5")
        let saved = try XCTUnwrap(cfg["original_statusline"] as? [String: Any])
        XCTAssertEqual(saved["customKey"] as? String, "x")
        // uninstall: birebir geri
        XCTAssertNil(try installer.uninstall())
        let restored = try XCTUnwrap(try statusLine())
        XCTAssertEqual(restored["command"] as? String, "my-status --flag")
        XCTAssertEqual(restored["refreshInterval"] as? Int, 5)
        XCTAssertEqual(restored["customKey"] as? String, "x")
        XCTAssertNil((try readJSON(config))["original_statusline"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDir.appendingPathComponent("blooper-statusline.sh").path))
    }

    func testSingleQuoteOriginalEscapedCorrectly() throws {
        let cmd = "echo 'hi there'"
        try write(settings, String(data: JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": cmd]]), encoding: .utf8)!)
        try installer.install()
        let wrapper = try String(contentsOf: binDir.appendingPathComponent("blooper-statusline.sh"), encoding: .utf8)
        XCTAssertTrue(wrapper.contains("echo '\\''hi there'\\''"), "tek tırnaklar '\\'' olarak kaçmalı")
        XCTAssertFalse(wrapper.contains("__BLOOPER_ORIGINAL__"))
    }

    func testEmbeddedFragmentInForeignPipelineIsForeign() throws {
        let cmd = "my-status | tee /dev/null && \"$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh\""
        try write(settings, String(data: JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": cmd]]), encoding: .utf8)!)
        XCTAssertFalse(installer.isInstalled(), "yolu içeren ama eşit olmayan komut yabancıdır")
        // Remove yabancıya dokunmaz
        _ = try? installer.uninstall()
        XCTAssertEqual((try statusLine())?["command"] as? String, cmd)
    }

    func testInstallIsIdempotent() throws {
        try write(settings, "{}")
        try installer.install()
        try installer.install()
        XCTAssertTrue((try statusLine())?["command"] as? String != nil)
    }

    func testDoubleWrapRejectedViaFileScan() throws {
        // yabancı script bizim marker'ı içeriyor (Blooper'ı sarmış) → kurulum reddedilir
        let foreign = binDir.appendingPathComponent("their-status.sh")
        try "#!/bin/bash\n# BLOOPER-STATUSLINE-WRAPPER v1 kopyası\necho hi\n".write(to: foreign, atomically: true, encoding: .utf8)
        try write(settings, String(data: JSONSerialization.data(withJSONObject:
            ["statusLine": ["type": "command", "command": foreign.path]]), encoding: .utf8)!)
        XCTAssertThrowsError(try installer.install()) { XCTAssertEqual($0 as? StatuslineError, .alreadyContainsBlooper) }
    }

    func testUninstallFragmentRemovesKey() throws {
        try write(settings, "{}")
        try installer.install()
        try installer.uninstall()
        XCTAssertNil(try statusLine())
        XCTAssertNil((try readJSON(settings))["statusLine"])
    }

    func testUninstallWrapperMissingOriginalFallsBack() throws {
        try write(settings, #"{"statusLine":{"type":"command","command":"my-status"}}"#)
        try installer.install()
        try write(config, "{}")   // original_statusline kaydını elle sil
        let msg = try installer.uninstall()
        XCTAssertNotNil(msg, "kayıp kayıtta kullanıcıya mesaj dönmeli")
        XCTAssertNil(try statusLine())
        XCTAssertFalse(FileManager.default.fileExists(atPath: binDir.appendingPathComponent("blooper-statusline.sh").path))
    }

    func testUninstallIsIdempotent() throws {
        try write(settings, "{}")
        try installer.install()
        try installer.uninstall()
        XCTAssertNoThrow(try installer.uninstall())
    }

    func testUnparsableSettingsUntouched() throws {
        try write(settings, "{broken")
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{broken")
    }

    func testForeignChangeAfterInstallInformsOnRemove() throws {
        try write(settings, #"{"statusLine":{"type":"command","command":"my-status"}}"#)
        try installer.install()
        // başka araç statusline'ı değiştirdi
        try write(settings, #"{"statusLine":{"type":"command","command":"other-tool"}}"#)
        let msg = try installer.uninstall()
        XCTAssertNotNil(msg, "yabancı + config'te sıkışmış kayıt → açıklayıcı mesaj")
        XCTAssertEqual((try statusLine())?["command"] as? String, "other-tool", "yabancıya dokunulmaz")
    }
}
```

- [ ] **Step 2: FAIL gör** — `swift test --filter StatuslineInstallerTests` → derleme hatası.

- [ ] **Step 3: Implementasyon**

```swift
import Foundation

enum StatuslineError: Error, Equatable {
    case unparsableSettings, unparsableConfig, alreadyContainsBlooper, templateMissing
}

struct StatuslineInstaller {
    let settingsURL: URL
    let configURL: URL
    let binDir: URL
    let templateURL: URL

    static let fragmentCommand = "\"$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh\""
    static let wrapperCommand  = "\"$HOME/Library/Application Support/Blooper/bin/blooper-statusline.sh\""
    private static let marker = "BLOOPER-STATUSLINE-WRAPPER"

    private var wrapperFile: URL { binDir.appendingPathComponent("blooper-statusline.sh") }

    private enum Kind { case none, fragment, wrapper, foreign }

    private func classify(_ root: [String: Any]) -> Kind {
        guard let sl = root["statusLine"] as? [String: Any],
              let cmd = (sl["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return .none }
        // Tam eşitlik ŞART: yolu içeren-ama-eşit-olmayan komut kullanıcının kendi zinciridir
        if cmd == Self.fragmentCommand { return .fragment }
        if cmd == Self.wrapperCommand { return .wrapper }
        return .foreign
    }

    func isInstalled() -> Bool {
        guard let root = try? readJSON(settingsURL) else { return false }
        switch classify(root) { case .fragment, .wrapper: return true; default: return false }
    }

    @discardableResult
    func install() throws -> String? {
        var root = try readJSONOrEmpty(settingsURL, error: .unparsableSettings)
        switch classify(root) {
        case .fragment: return nil                       // idempotent
        case .wrapper:
            try regenerateWrapperIfVersionChanged()
            return nil
        case .none:
            root["statusLine"] = ["type": "command", "command": Self.fragmentCommand, "refreshInterval": 30]
            try backupAndWrite(root)
            return nil
        case .foreign:
            let original = root["statusLine"] as! [String: Any]
            let cmd = (original["command"] as? String) ?? ""
            if foreignScriptContainsMarker(cmd) { throw StatuslineError.alreadyContainsBlooper }
            try saveOriginalToConfig(original)
            try generateWrapper(original: cmd)
            var sl = original
            sl["command"] = Self.wrapperCommand
            root["statusLine"] = sl                      // diğer anahtarlar settings'te korunur
            try backupAndWrite(root)
            return nil
        }
    }

    @discardableResult
    func uninstall() throws -> String? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        var root = try readJSONOrEmpty(settingsURL, error: .unparsableSettings)
        switch classify(root) {
        case .none: return nil
        case .fragment:
            root.removeValue(forKey: "statusLine")
            try backupAndWrite(root)
            return nil
        case .wrapper:
            defer { try? FileManager.default.removeItem(at: wrapperFile) }
            if let original = try takeOriginalFromConfig() {
                root["statusLine"] = original
                try backupAndWrite(root)
                return nil
            }
            root.removeValue(forKey: "statusLine")       // fallback: fragment-dalı davranışı
            try backupAndWrite(root)
            return "Orijinal statusline kaydı bulunamadı; gerekirse settings.json.blooper-backup dosyasından geri alabilirsiniz."
        case .foreign:
            if (try? takeOriginalFromConfig(peek: true)) != nil {
                return "Statusline başka bir araç tarafından değiştirilmiş; Blooper dokunmuyor. Orijinal kaydınız config.json içinde 'original_statusline' olarak duruyor."
            }
            return nil                                    // idempotent: bizden iz yok
        }
    }

    // MARK: - iç yardımcılar

    private func regenerateWrapperIfVersionChanged() throws {
        let current = (try? String(contentsOf: wrapperFile, encoding: .utf8)) ?? ""
        let template = try templateText()
        let versionLine = template.split(separator: "\n").first { $0.contains(Self.marker) }.map(String.init) ?? ""
        guard !current.contains(versionLine) else { return }
        // sürüm farklı: config'teki orijinalle yeniden üret
        if let original = try takeOriginalFromConfig(peek: true),
           let cmd = original["command"] as? String {
            try generateWrapper(original: cmd)
        }
    }

    private func foreignScriptContainsMarker(_ command: String) -> Bool {
        // best-effort: interpreter token'larını soy, tırnakları çöz, $HOME/~ genişlet
        var tokens = command.split(separator: " ").map(String.init)
        while let first = tokens.first, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(first) {
            tokens.removeFirst()
        }
        guard var path = tokens.first else { return false }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        path = path.replacingOccurrences(of: "$HOME", with: home)
        if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
        guard FileManager.default.isReadableFile(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return content.contains(Self.marker)
    }

    private func generateWrapper(original: String) throws {
        let template = try templateText()
        // Tek güvenli kaçış: ' → '\''  (bash tek-tırnaklı string'de tek metakarakter ' işaretidir)
        let escaped = original.replacingOccurrences(of: "'", with: "'\\''")
        let content = template.replacingOccurrences(of: "__BLOOPER_ORIGINAL__", with: escaped)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try content.write(to: wrapperFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperFile.path)
    }

    private func templateText() throws -> String {
        guard let text = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw StatuslineError.templateMissing
        }
        return text
    }

    private func saveOriginalToConfig(_ original: [String: Any]) throws {
        var cfg = try readJSONOrEmpty(configURL, error: .unparsableConfig)   // RMW: diğer anahtarlar korunur
        cfg["original_statusline"] = original
        try writeJSON(cfg, to: configURL)
    }

    private func takeOriginalFromConfig(peek: Bool = false) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        guard var cfg = try? readJSON(configURL) else { return nil }         // bozuk config = kayıt yok say
        guard let original = cfg["original_statusline"] as? [String: Any] else { return nil }
        if !peek {
            cfg.removeValue(forKey: "original_statusline")
            try writeJSON(cfg, to: configURL)
        }
        return original
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StatuslineError.unparsableSettings
        }
        return obj
    }

    private func readJSONOrEmpty(_ url: URL, error: StatuslineError) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw error }
        return obj
    }

    private func backupAndWrite(_ root: [String: Any]) throws {
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.blooper-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: settingsURL, to: backup)
        }
        try writeJSON(root, to: settingsURL)
    }

    private func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: PASS** — `swift test --filter StatuslineInstallerTests` → 12 test yeşil; ardından tam takım.

- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat: add statusline installer with safe wrap and exact restore"`

---

### Task 6: UI + sync + bundle + README

**Files:**
- Modify: `Sources/Blooper/Environment.swift`, `Sources/Blooper/Views/MenuView.swift`, `Sources/Blooper/BlooperApp.swift`, `scripts/bundle.sh`, `README.md`

**Interfaces:**
- Consumes: `StatuslineInstaller` (Task 5).
- Produces: menüde "Install statusline"/"Remove statusline" + bilgi mesajı alanı; bundle'da fragment + şablon.

- [ ] **Step 1: Environment sync listesi** — `syncScripts` döngüsündeki listeyi `["hook.sh", "checker.sh", "statusline-fragment.sh"]` yap. (Şablon senkronlanmaz — wrapper üretimi şablonu doğrudan Bundle'dan okur.)

- [ ] **Step 2: MenuView** — hook butonu satırının altına:

```swift
            HStack {
                Button(statuslineInstalled ? "Remove statusline" : "Install statusline") { toggleStatusline() }
                Spacer()
            }
            if let statuslineInfo {
                Text(statuslineInfo).font(.caption).foregroundStyle(.secondary)
            }
```

State + aksiyon (`toggleHook` yanına):

```swift
    @State private var statuslineInstalled = false
    @State private var statuslineInfo: String?

    private func toggleStatusline() {
        do {
            let msg: String?
            if statuslineInstalled { msg = try statuslineInstaller.uninstall() }
            else { msg = try statuslineInstaller.install() }
            statuslineInstalled = statuslineInstaller.isInstalled()
            statuslineInfo = msg ?? (statuslineInstalled ? "Statusline installed — visible after your next interaction." : nil)
        } catch StatuslineError.alreadyContainsBlooper {
            statuslineInfo = "Your statusline already includes Blooper — resolve manually first."
        } catch {
            statuslineInfo = "Couldn't parse settings.json — left untouched. Fix it manually and retry."
        }
    }
```

`MenuView`'a `let statuslineInstaller: StatuslineInstaller` parametresi ekle; `.onAppear`'da `statuslineInstalled = statuslineInstaller.isInstalled()`.

- [ ] **Step 3: BlooperApp** — installer'ı kur ve geç:

```swift
    private let statuslineInstaller = StatuslineInstaller(
        settingsURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
        configURL: BlooperEnv.configFile,
        binDir: BlooperEnv.binDir,
        templateURL: Bundle.main.url(forResource: "statusline-wrapper-template", withExtension: "sh")
            ?? BlooperEnv.binDir.appendingPathComponent("statusline-wrapper-template.sh"))
```

(`MenuView(store:installer:statuslineInstaller:)` çağrısı güncellenir.)

- [ ] **Step 4: bundle.sh** — kopya satırını genişlet:

```bash
cp Resources/scripts/hook.sh Resources/scripts/checker.sh \
   Resources/scripts/statusline-fragment.sh Resources/scripts/statusline-wrapper-template.sh \
   "$APP/Contents/Resources/"
```

- [ ] **Step 5: README'ye "Statusline" bölümü** (Install bölümünden sonra):

```markdown
## Statusline (optional)

Show this session's recent mistakes right under the Claude Code input box:
menu bar icon → **Install statusline**.

- No statusline configured? Blooper installs its own (refreshes every 30s).
- Already have one (plugin or custom)? Blooper wraps it: your line renders
  first, mistakes appear under it. **Remove statusline** restores your
  original setup exactly. If you later change your own statusline, run
  Remove + Install again so Blooper wraps the new one.
- Power users: add this line to the end of your own statusline script instead
  and skip the wrapper entirely:
  `printf '%s' "$payload" | "$HOME/Library/Application Support/Blooper/bin/statusline-fragment.sh"`
- Notes: mistakes are session-scoped (each Claude window sees its own);
  installing a statusline hides Claude Code's built-in shortcut hints; a
  project-level `.claude/settings.json` statusline overrides the user-level one.
```

- [ ] **Step 6: Build + tüm testler** — `swift build && swift test && tests/scripts/run.sh` → hepsi yeşil.

- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat: add statusline install flow to menu and docs"`

---

### Task 7: Gerçek-ortam smoke + v0.2.0 release

- [ ] **Step 1: Bundle üret + app'i yeniden başlat** — `scripts/bundle.sh 0.2.0 && killall Blooper; open build/Blooper.app`
- [ ] **Step 2: Kullanıcı smoke'u (elle):** menüden Install statusline → ponytail çıktısı + (İngilizce hatalı prompt sonrası) altında hata satırları; ikinci Claude penceresinde o pencerenin hataları; Remove statusline → ponytail objesi birebir geri (`plutil -p ~/.claude/settings.json` ile teyit).
- [ ] **Step 3: (Kullanıcı onayıyla) release** — `git push && scripts/release.sh 0.2.0` (yeni logo bu .dmg'ye dahil).

## Task sırası

1 → 2 → 3 → 4 → 5 → 6 → 7. (3 ve 4, 1'in JSONL şemasına; 5, 4'ün şablonuna; 6, 5'e bağlıdır.)
