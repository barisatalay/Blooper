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

test_hook_recursion_guard
test_hook_large_prompt
test_hook_returns_fast_with_slow_checker
test_hook_tricky_prompts_no_crash
test_hook_malformed_payload_failopen
test_hook_missing_checker_failopen

printf '\n%d failure(s)\n' "$FAILS"
exit "$FAILS"
