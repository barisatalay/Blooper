#!/bin/bash
# Statusline parçası: bu oturumda son 10 dakikada yakalanan hatalar (en fazla 3 satır).
# Her hata yolu fail-open: exit 0 + boş çıktı — statusline asla bozulmaz.
SUPPORT_DIR="${BLOOPER_SUPPORT_DIR:-$HOME/Library/Application Support/Blooper}"
FILE="$SUPPORT_DIR/mistakes.jsonl"

# TTY guard: terminalde elle çalıştıran EOF beklemesin (global moda düşer)
[ -t 0 ] && payload="" || payload=$(cat)
# session_id yoksa plutil hata metnini STDOUT'a basar (rc=1) — || reset'i yük taşıyan parçadır
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
        if (isNaN(t) || now - t > 600) continue;            // 10 dk penceresi
        if (session && m.session !== session) continue;      // oturum filtresi (boşsa global)
        hits.push(m);
    }
    const E = "\u001b";
    const R = E + "[0m";
    return hits.slice(-3).map(m =>
        E + "[31m" + m.wrong + R + " → " + E + "[32m" + m.right + R + " · " + (m.rule || "") + R
    ).join("\n");
}' "$FILE" "$session_id" "$now" 2>/dev/null) || exit 0

[ -n "$res" ] && printf '%s\n' "$res"
exit 0
