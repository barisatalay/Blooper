#!/bin/bash
# İngilizce hata kontrolü — arka planda koşar, her hata yolu sessiz çıkar (fail-open).
export BLOOPER_CHECK=1   # claude'dan ÖNCE: iç oturumun hook'u zinciri ilk adımda kessin

SUPPORT_DIR="${BLOOPER_SUPPORT_DIR:-$HOME/Library/Application Support/Blooper}"
LOG="$SUPPORT_DIR/last-error.log"
tmpfile="${1:-}"
session="${2:-}"
outfile=""
cleanup() { rm -f "$tmpfile" "$outfile"; }
trap cleanup EXIT

[ -n "$tmpfile" ] && [ -f "$tmpfile" ] || exit 0
text=$(cat "$tmpfile")

# --- Ön-filtre: API çağrısı yapmadan ele ---
case "$text" in
    /*|\#*) exit 0 ;;      # slash command / memory kısayolu
    *'```'*) exit 0 ;;     # kod bloklu prompt — dil kontrolü anlamsız
esac
words=$(printf '%s' "$text" | wc -w | tr -d ' ')
[ "$words" -lt 4 ] && exit 0
total=$(printf '%s' "$text" | wc -c | tr -d ' ')
ascii=$(printf '%s' "$text" | LC_ALL=C tr -cd '\1-\177' | wc -c | tr -d ' ')
# ASCII-dışı oran > %10 ise İngilizce sayma (Türkçe/Rusça vb.)
[ $((ascii * 10)) -lt $((total * 9)) ] && exit 0

# --- claude binary çözümlemesi (hook ortamında PATH minimal olabilir) ---
CLAUDE_BIN=$(command -v claude 2>/dev/null)
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.claude/local/claude" ] && CLAUDE_BIN="$HOME/.claude/local/claude"
[ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ] && CLAUDE_BIN="$HOME/.local/bin/claude"
if [ -z "$CLAUDE_BIN" ]; then printf 'claude binary not found\n' > "$LOG"; exit 0; fi

# --- Config: model (yoksa/bozuksa sessizce default) ---
# Dikkat: dosya yoksa plutil hata METNİNİ stdout'a (-o - hedefine) basar; rc kontrolü şart
model=$(plutil -extract model raw -o - "$SUPPORT_DIR/config.json" 2>/dev/null) || model=""
[ -z "$model" ] && model="claude-haiku-4-5"

# --- İzole oturum: kullanıcının proje bağlamı/MCP/hook'ları yüklenmez ---
cd "$SUPPORT_DIR" || exit 0
outfile=$(mktemp "${TMPDIR:-/tmp}/blooper-out.XXXXXX") || exit 0

SCHEMA='{"type":"object","properties":{"mistakes":{"type":"array","items":{"type":"object","properties":{"wrong":{"type":"string"},"right":{"type":"string"},"rule":{"type":"string"}},"required":["wrong","right","rule"]}}},"required":["mistakes"]}'
SYSTEM='You are an English mistake logger. The user message is text a developer typed. Report only real English language errors (grammar, word choice, spelling). For each error give: wrong (the erroneous fragment), right (corrected fragment), rule (short explanation). If the text is not English, or has no errors, return an empty mistakes array. Never give style advice.'

"$CLAUDE_BIN" -p --model "$model" --output-format json \
    --system-prompt "$SYSTEM" --max-turns 1 --tools "" \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --settings '{"disableAllHooks":true}' --no-session-persistence \
    --json-schema "$SCHEMA" \
    < "$tmpfile" > "$outfile" 2>>"$LOG" &
pid=$!
# macOS'ta GNU timeout yok: shell-native watchdog
(sleep 30; kill "$pid" 2>/dev/null) & wpid=$!
wait "$pid"; rc=$?
# wait olmadan kill, job-control "Terminated" gürültüsü basar
{ kill "$wpid"; wait "$wpid"; } 2>/dev/null

# stderr append'i sınırsız büyütmesin: 64KB üstünü kırp
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
    tail -c 65536 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

is_error=$(plutil -extract is_error raw -o - - < "$outfile" 2>/dev/null)
if [ "$rc" -ne 0 ] || [ "$is_error" = "true" ]; then
    # zarf subtype:"success" dönebilir (yanıltıcı) — ona bakılmaz; .result teşhis için loglanır
    { printf 'check failed rc=%s\n' "$rc"; plutil -extract result raw -o - - < "$outfile" 2>/dev/null; } > "$LOG"
    exit 0
fi

mistakes=$(plutil -extract structured_output.mistakes json -o - - < "$outfile" 2>/dev/null)
if [ -z "$mistakes" ]; then cat "$outfile" > "$LOG"; exit 0; fi

# JSONL üretimi osascript/JXA ile: elle string birleştirme = kaçış hatası riski
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
osascript -l JavaScript -e '
function run(argv) {
    const arr = JSON.parse(argv[0]);
    const ts = argv[1];
    const session = argv[2];
    return arr.map(m => {
        const o = {ts: ts, wrong: m.wrong, right: m.right, rule: m.rule};
        if (session) o.session = session;
        return JSON.stringify(o);
    }).join("\n");
}' "$mistakes" "$ts" "$session" 2>>"$LOG" | while IFS= read -r line; do
    # satır başına tek printf = tek write; eşzamanlı checker'larda interleave olmaz
    [ -n "$line" ] && printf '%s\n' "$line" >> "$SUPPORT_DIR/mistakes.jsonl"
done
exit 0
