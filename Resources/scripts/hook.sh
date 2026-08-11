#!/bin/bash
# Fail-open: her hata yolu 0 ile çıkar; Claude oturumu asla bloklanmaz.
[ -n "$BLOOPER_CHECK" ] && exit 0

SUPPORT_DIR="${BLOOPER_SUPPORT_DIR:-$HOME/Library/Application Support/Blooper}"
CHECKER="$SUPPORT_DIR/bin/checker.sh"
[ -x "$CHECKER" ] || exit 0

# jq yok: prompt alanını macOS-yerleşik plutil ile çıkar
prompt=$(plutil -extract prompt raw -o - - 2>/dev/null) || exit 0
[ -z "$prompt" ] && exit 0

tmpfile=$(mktemp "${TMPDIR:-/tmp}/blooper.XXXXXX") || exit 0
printf '%s' "$prompt" > "$tmpfile"

# Tam detach: fd'ler kapatılmazsa Claude Code EOF görmez ve hook timeout'una dek bekler
"$CHECKER" "$tmpfile" </dev/null >/dev/null 2>&1 &
exit 0
