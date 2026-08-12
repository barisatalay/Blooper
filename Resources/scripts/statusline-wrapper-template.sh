#!/bin/bash
# BLOOPER-STATUSLINE-WRAPPER v1 — kaldırmak için Blooper menüsünü kullanın.
# Orijinal statusline BLOOPER_ORIGINAL değişkenindedir; restore kaynağı config.json'dur (bu dosya değil).
BLOOPER_ORIGINAL='__BLOOPER_ORIGINAL__'
# Test izolasyonu için env override (hook/checker'daki desen); üretimde unset → aynı yol
FRAGMENT="${BLOOPER_SUPPORT_DIR:-$HOME/Library/Application Support/Blooper}/bin/statusline-fragment.sh"
# TTY guard: elle çalıştıran EOF beklemesin
[ -t 0 ] && payload="" || payload=$(cat)
# Orijinal alt shell'de koşar (çok satır, ;, &&, # ve quoting güvenli); çıktı newline-normalize
# edilir — orijinal sona newline basmazsa fragment ilk satırına yapışırdı.
out=$(printf '%s' "$payload" | /bin/bash -c "$BLOOPER_ORIGINAL" 2>/dev/null)
[ -n "$out" ] && printf '%s\n' "$out"
[ -x "$FRAGMENT" ] && printf '%s' "$payload" | "$FRAGMENT"
exit 0
