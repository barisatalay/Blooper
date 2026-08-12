#!/bin/bash
# Fail-open: her hata yolu 0 ile çıkar; Claude oturumu asla bloklanmaz.
[ -n "$BLOOPER_CHECK" ] && exit 0

SUPPORT_DIR="${BLOOPER_SUPPORT_DIR:-$HOME/Library/Application Support/Blooper}"
CHECKER="$SUPPORT_DIR/bin/checker.sh"
[ -x "$CHECKER" ] || exit 0

# stdin TEK KEZ okunabilir: payload buffer'lanır, alanlar ondan ayrı ayrı çıkarılır
# (jq yok: macOS-yerleşik plutil kullanılır)
payload=$(cat)
prompt=$(printf '%s' "$payload" | plutil -extract prompt raw -o - - 2>/dev/null) || exit 0
[ -z "$prompt" ] && exit 0
# session_id yoksa plutil hata metnini STDOUT'a basar (rc=1) — || reset'i yük taşıyan parçadır
session_id=$(printf '%s' "$payload" | plutil -extract session_id raw -o - - 2>/dev/null) || session_id=""

tmpfile=$(mktemp "${TMPDIR:-/tmp}/blooper.XXXXXX") || exit 0
printf '%s' "$prompt" > "$tmpfile"

# Tam detach: fd'ler kapatılmazsa Claude Code EOF görmez ve hook timeout'una dek bekler
"$CHECKER" "$tmpfile" "$session_id" </dev/null >/dev/null 2>&1 &
exit 0
