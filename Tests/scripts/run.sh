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

printf '\n%d failure(s)\n' "$FAILS"
exit "$FAILS"
