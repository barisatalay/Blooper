#!/bin/bash
# Blooper script testleri — stok macOS'ta koşar, dış bağımlılık yok, gerçek claude çağrılmaz.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAILS=0
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS+1)); }
pass() { printf 'ok:   %s\n' "$1"; }

setup_env() {
    # macOS TMPDIR sondaki slash ile gelir; // yolu cd sonrası $PWD ile eşleşmez
    tmpbase="${TMPDIR:-/tmp}"; tmpbase="${tmpbase%/}"
    WORK=$(mktemp -d "$tmpbase/blooper-test.XXXXXX")
    export BLOOPER_SUPPORT_DIR="$WORK/support dir/Blooper"   # kasıtlı boşluklu yol
    mkdir -p "$BLOOPER_SUPPORT_DIR/bin"
    cp "$ROOT/Resources/scripts/hook.sh" "$BLOOPER_SUPPORT_DIR/bin/"
    cp "$ROOT/Resources/scripts/checker.sh" "$BLOOPER_SUPPORT_DIR/bin/" 2>/dev/null || true
    cp "$ROOT/Resources/scripts/statusline-fragment.sh" "$BLOOPER_SUPPORT_DIR/bin/" 2>/dev/null || true
    chmod +x "$BLOOPER_SUPPORT_DIR/bin/"*.sh
    export STUB_LOG="$WORK/stub.log"; : > "$STUB_LOG"
    export PATH="$ROOT/tests/scripts/stubs:$PATH"
    unset BLOOPER_CHECK STUB_SLEEP STUB_RESPONSE_FILE STUB_EXIT 2>/dev/null || true
}

hook_payload() { printf '{"session_id":"s","prompt":%s}' "$1"; }

test_hook_recursion_guard() {
    setup_env
    # rc=0 assert'i yetmez: hook zaten her yolda 0 döner. Guard'ın kanıtı checker'ın HİÇ çağrılmaması.
    printf '#!/bin/bash\necho CALLED >> "%s"\n' "$STUB_LOG" > "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    chmod +x "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    hook_payload '"I am agree with you"' | BLOOPER_CHECK=1 "$BLOOPER_SUPPORT_DIR/bin/hook.sh" || { fail "guard: rc!=0"; return; }
    sleep 1
    grep -q CALLED "$STUB_LOG" && { fail "guard: checker yine de çağrıldı"; return; }
    pass "hook recursion guard"
}

test_hook_large_prompt() {
    setup_env
    printf '#!/bin/bash\nwc -c < "$1" | tr -d " " >> "%s"\n' "$STUB_LOG" > "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    chmod +x "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    big=$(printf 'word %.0s' $(seq 1 40000))   # ~200KB
    hook_payload "\"$big\"" | "$BLOOPER_SUPPORT_DIR/bin/hook.sh" || { fail "large prompt rc!=0"; return; }
    sleep 1
    n=$(tail -1 "$STUB_LOG")
    [ "${n:-0}" -ge 190000 ] || { fail "large prompt kırpıldı: $n"; return; }
    pass "hook 200KB prompt"
}

test_hook_returns_fast_with_slow_checker() {
    setup_env
    # checker'ı 5 sn'lik sahte script'le değiştir; hook yine <1 sn dönmeli
    printf '#!/bin/bash\nsleep 5\n' > "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    chmod +x "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    start=$(date +%s)
    hook_payload '"I am agree with you"' | "$BLOOPER_SUPPORT_DIR/bin/hook.sh"
    rc=$?; end=$(date +%s)
    [ "$rc" -eq 0 ] || { fail "detach: rc=$rc"; return; }
    [ $((end - start)) -le 1 ] || { fail "detach: hook $((end-start))s sürdü"; return; }
    pass "hook detaches (wall-clock <=1s)"
}

test_hook_tricky_prompts_no_crash() {
    setup_env
    printf '#!/bin/bash\ncat "$1" >> "%s"\n' "$STUB_LOG" > "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    chmod +x "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    for p in '"multi\nline \"quoted\" text here"' '"emoji 😀 and $(dangerous) `cmd` text"'; do
        hook_payload "$p" | "$BLOOPER_SUPPORT_DIR/bin/hook.sh" || { fail "tricky prompt rc!=0"; return; }
    done
    sleep 1  # detach'li checker'ın yazması için
    grep -q 'quoted' "$STUB_LOG" || { fail "tricky: prompt checker'a ulaşmadı"; return; }
    grep -q 'dangerous' "$STUB_LOG" || { fail "tricky: emoji/injection prompt ulaşmadı"; return; }
    pass "hook tricky prompts"
}

test_hook_malformed_payload_failopen() {
    setup_env
    printf 'not json at all' | "$BLOOPER_SUPPORT_DIR/bin/hook.sh"
    [ $? -eq 0 ] || { fail "malformed payload rc!=0"; return; }
    pass "hook malformed payload fail-open"
}

test_hook_missing_checker_failopen() {
    setup_env
    rm -f "$BLOOPER_SUPPORT_DIR/bin/checker.sh"
    hook_payload '"some english text here"' | "$BLOOPER_SUPPORT_DIR/bin/hook.sh"
    [ $? -eq 0 ] || { fail "missing checker rc!=0"; return; }
    pass "hook missing checker fail-open"
}

checker_fixture_ok() {
    cat > "$WORK/response.json" <<'EOF'
{"type":"result","subtype":"success","is_error":false,"result":"done","structured_output":{"mistakes":[{"wrong":"I am agree","right":"I agree","rule":"agree is a verb"}]}}
EOF
    export STUB_RESPONSE_FILE="$WORK/response.json"
}

run_checker() { # $1 = prompt metni, $2 = session (opsiyonel)
    tf=$(mktemp "$WORK/prompt.XXXXXX"); printf '%s' "$1" > "$tf"
    "$BLOOPER_SUPPORT_DIR/bin/checker.sh" "$tf" "${2:-}"
}

test_checker_happy_path() {
    setup_env; checker_fixture_ok
    run_checker "I am agree with you post here" || { fail "checker rc!=0"; return; }
    line=$(tail -1 "$BLOOPER_SUPPORT_DIR/mistakes.jsonl" 2>/dev/null)
    printf '%s' "$line" | plutil -extract wrong raw -o - - >/dev/null 2>&1 || { fail "jsonl satırı geçersiz: $line"; return; }
    case "$line" in *'"I am agree"'*) pass "checker happy path" ;; *) fail "jsonl içerik: $line" ;; esac
}

test_checker_empty_mistakes_writes_nothing() {
    setup_env
    printf '{"is_error":false,"result":"ok","structured_output":{"mistakes":[]}}' > "$WORK/response.json"
    export STUB_RESPONSE_FILE="$WORK/response.json"
    run_checker "This sentence is perfectly fine thanks"
    [ -f "$BLOOPER_SUPPORT_DIR/mistakes.jsonl" ] && { fail "boş sonuçta dosya yazıldı"; return; }
    pass "checker empty result writes nothing"
}

test_checker_prefilter_skips_turkish_short_slash() {
    setup_env; checker_fixture_ok
    run_checker "Türkçe karakterli bir metin şöyle olur çünkü öğle üzeri"
    run_checker "too short"
    run_checker "/gtc-be-code-review some args here"
    run_checker 'Please review this snippet ``` let x = 1 ``` for me quickly'
    [ -s "$STUB_LOG" ] && { fail "ön-filtre delindi: $(cat "$STUB_LOG")"; return; }
    pass "checker pre-filter (turkish/short/slash/code) no api call"
}

test_checker_broken_output_failopen() {
    setup_env
    printf 'this is not json' > "$WORK/response.json"
    export STUB_RESPONSE_FILE="$WORK/response.json"
    run_checker "I am agree with you post here" || { fail "broken output rc!=0"; return; }
    [ -f "$BLOOPER_SUPPORT_DIR/mistakes.jsonl" ] && { fail "bozuk çıktıda jsonl yazıldı"; return; }
    [ -s "$BLOOPER_SUPPORT_DIR/last-error.log" ] || { fail "last-error.log boş"; return; }
    pass "checker broken output fail-open + logged"
}

test_checker_is_error_envelope() {
    setup_env
    printf '{"is_error":true,"subtype":"success","result":"Not logged in"}' > "$WORK/response.json"
    export STUB_RESPONSE_FILE="$WORK/response.json"
    run_checker "I am agree with you post here"
    grep -q "Not logged in" "$BLOOPER_SUPPORT_DIR/last-error.log" || { fail "is_error .result loglanmadı"; return; }
    pass "checker is_error envelope logged"
}

test_checker_watchdog_kills_stuck_claude() {
    setup_env; checker_fixture_ok
    export STUB_SLEEP=40
    # Watchdog süresi sabit 30 sn; bu test uzun koşar, RUN_SLOW=1 olmadan atla
    if [ "${RUN_SLOW:-0}" != "1" ]; then pass "checker watchdog (SKIP: RUN_SLOW=1 ile koş)"; return; fi
    start=$(date +%s)
    run_checker "I am agree with you post here"
    end=$(date +%s)
    [ $((end - start)) -le 33 ] || { fail "watchdog çalışmadı: $((end-start))s"; return; }
    pass "checker watchdog kills stuck claude"
}

test_checker_stub_env_isolation() {
    setup_env; checker_fixture_ok
    run_checker "I am agree with you post here"
    grep -q 'ENV_BLOOPER_CHECK:1' "$STUB_LOG" || { fail "BLOOPER_CHECK stub'a miras kalmadı"; return; }
    grep -q "CWD:$BLOOPER_SUPPORT_DIR" "$STUB_LOG" || { fail "cd SUPPORT_DIR yapılmadı"; return; }
    grep -q -- '--no-session-persistence' "$STUB_LOG" || { fail "izolasyon bayrakları eksik"; return; }
    grep -q -- '--model claude-haiku-4-5' "$STUB_LOG" || { fail "default model haiku değil"; return; }
    pass "checker env+flag isolation"
}

test_checker_config_model_override() {
    setup_env; checker_fixture_ok
    printf '{"model":"claude-sonnet-5"}' > "$BLOOPER_SUPPORT_DIR/config.json"
    run_checker "I am agree with you post here"
    grep -q -- '--model claude-sonnet-5' "$STUB_LOG" || { fail "config model okunmadı"; return; }
    pass "checker config model override"
}

test_checker_concurrent_runs() {
    setup_env; checker_fixture_ok
    run_checker "I am agree with you post one" &
    run_checker "I am agree with you post two" &
    wait
    n=$(wc -l < "$BLOOPER_SUPPORT_DIR/mistakes.jsonl" | tr -d ' ')
    [ "$n" -eq 2 ] || { fail "eşzamanlı koşuda $n satır (2 bekleniyordu)"; return; }
    pass "checker concurrent runs append 2 valid lines"
}

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

test_fragment_closed_stdin_global() {
    setup_env
    write_mistake 60 "s1" "I am agree"
    out=$(FRAG </dev/null)                           # payload hiç yok (kapalı stdin) → global mod
    case "$out" in *"I am agree"*) pass "fragment global fallback (closed stdin)" ;; *) fail "kapalı-stdin düşüşü çalışmadı" ;; esac
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
    # Pipeline-subshell tuzağı: while'ı pipe'a bağlarsak fail() sayacı subshell'de kalır,
    # suite yanlışı yeşil raporlar. Çıktı önce değişkene alınır, here-string ile döngülenir.
    out=$(sl_payload '"s1"' | FRAG)
    bad=0
    while IFS= read -r line; do
        case "$line" in *$'\033[0m') : ;; *) bad=1 ;; esac
    done <<< "$out"
    [ "$bad" -eq 0 ] || { fail "satır(lar) reset ile bitmiyor"; return; }
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

make_wrapper() { # $1 = orijinal komut; üretilen wrapper yolunu basar
    # Substitüsyon satır-birleştirmeyle yapılır (sed/perl replacement'ta özel karakter tuzağı yok):
    # placeholder satırı atılır, yerine kaçışlı orijinali taşıyan atama satırı yazılır.
    esc=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
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
    # (head -c pipe'ı tamponla tümüyle çeker — bayt-hassas tüketim için dd şart)
    w=$(make_wrapper 'dd bs=1 count=5 >/dev/null 2>&1; wc -c | tr -d " "')
    out=$(printf '{"session_id":"s1"}' | "$w")
    first=$(printf '%s\n' "$out" | head -1)
    total=$(printf '{"session_id":"s1"}' | wc -c | tr -d ' ')
    [ "$first" = "$((total - 5))" ] || { fail "grup stdin paylaşımı beklenen değil: $first"; return; }
    pass "wrapper group shares payload pipe natively"
}

test_hook_recursion_guard
test_hook_large_prompt
test_hook_returns_fast_with_slow_checker
test_hook_tricky_prompts_no_crash
test_hook_malformed_payload_failopen
test_hook_missing_checker_failopen
test_checker_happy_path
test_checker_empty_mistakes_writes_nothing
test_checker_prefilter_skips_turkish_short_slash
test_checker_broken_output_failopen
test_checker_is_error_envelope
test_checker_watchdog_kills_stuck_claude
test_checker_stub_env_isolation
test_checker_config_model_override
test_checker_concurrent_runs
test_checker_session_in_jsonl
test_checker_no_session_no_field
test_hook_passes_session_to_checker
test_hook_missing_session_still_checks
test_fragment_matching_session_fresh
test_fragment_other_session_hidden
test_fragment_stale_hidden
test_fragment_caps_at_three
test_fragment_no_session_field_global
test_fragment_closed_stdin_global
test_fragment_empty_and_garbage
test_fragment_ansi_reset_per_line
test_fragment_tail_200_limit
test_wrapper_original_then_fragment
test_wrapper_no_trailing_newline_original
test_wrapper_multiline_and_quote_original
test_wrapper_failing_original_failopen
test_wrapper_group_shares_stdin_native

printf '\n%d failure(s)\n' "$FAILS"
exit "$FAILS"
