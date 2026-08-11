# Blooper

Catch your English mistakes while chatting with Claude Code — right in your macOS menu bar.

Blooper watches the prompts you send to Claude Code, checks them for English
mistakes in the background (using your own Claude subscription via `claude -p`),
and collects the corrections in a menu bar app: what you got wrong, the fix,
the rule, and how often you repeat it.

## Requirements

- macOS 14+ (Apple Silicon or Intel)
- [Claude Code](https://claude.com/claude-code) installed and logged in

## Install

1. Download `Blooper-x.y.z.dmg` from [Releases](../../releases), drag **Blooper** to **Applications**.
2. First launch (unsigned app):
   - **macOS 15+:** open once, then System Settings → Privacy & Security → **Open Anyway** (needed only the first time).
   - **macOS 14:** right-click Blooper.app → **Open**.
   - Alternative: `xattr -d com.apple.quarantine /Applications/Blooper.app`
3. Launch Blooper, click the menu bar icon → **Install Claude Code hook**.
4. Write English prompts in Claude Code. Mistakes show up in the menu bar.

## How it works

A `UserPromptSubmit` hook hands your prompt to a fully detached background
script. The script runs an isolated, tool-less `claude -p` call (default model:
`claude-haiku-4-5`) and appends any mistakes to
`~/Library/Application Support/Blooper/mistakes.jsonl`. The app watches that
file. Your Claude session is never blocked or delayed — every failure path in
the pipeline exits silently.

- Checks use **your** Claude subscription; each English prompt costs one small
  background call (typically a fraction of a cent, up to a few cents depending
  on model and caching). Change the model in
  `~/Library/Application Support/Blooper/config.json`.
- Mistake fragments from your prompts are stored as plain text in the JSONL
  file above. Nothing leaves your machine except the check call itself, and
  check sessions are not persisted by Claude Code.
- Notifications are best-effort on unsigned apps; the menu bar counter always works.

## Uninstall

1. Menu bar icon → **Remove hook** (this edits `~/.claude/settings.json`; a
   backup is kept as `settings.json.blooper-backup`).
2. Delete `/Applications/Blooper.app` and `~/Library/Application Support/Blooper`.

If you deleted the app first: remove the Blooper entry from
`hooks.UserPromptSubmit` in `~/.claude/settings.json` manually.

## Build from source

```bash
swift build            # development build
swift test             # unit tests
tests/scripts/run.sh   # shell script tests (no real API calls)
scripts/bundle.sh      # build/Blooper.app (universal)
```

## License

MIT
