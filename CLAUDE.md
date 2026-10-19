# DevDisk

Native macOS app (Swift, Apple Silicon, macOS 14+) that finds disk space left behind by dev work and
cleans it with each tool's own clean command. The UI is a local HTML page in a WKWebView. No
dependencies on either side: plain Swift (AppKit/WebKit/Foundation) and plain HTML/CSS/JS.

## Build and run

```sh
./build.sh                       # dist/DevDisk.app, signed with an Apple Development identity (or ad-hoc if none)
./build.sh --adhoc               # ad-hoc signed
VERSION=1.0 ./build.sh --release # Developer ID + notarized DMG (needs setup, see README)
open dist/DevDisk.app
dist/DevDisk.app/Contents/MacOS/DevDisk --json   # headless scan as JSON; doesn't write history
```

There are no tests. Verify a change with a `--json` scan, by running the app, or by rendering `Web/` in
headless Chrome with fake data (call `App.receive({type:'result', payload})`). Quit and reopen the app
after a rebuild. The Web files are copied into the bundle at build time.

## Layout

- `Sources/DevDisk/main.swift`: window, WKWebView, menu and the JS bridge (`bridge` handler).
  Page → Swift commands: `ready`, `setProtected`, `scan`, `clean` (ids), `stopClean`, `reveal`.
  Swift → page: `App.receive(msg)`.
- `Sources/DevDisk/Rules.swift`: everything the scan looks for. `Rules.globals` are fixed paths under ~
  and `Rules.projectRules` are folders found inside projects (gated by marker files). Also
  `skipTopLevel`, `protectedFolders` and `cloudPrefixes`.
- `Sources/DevDisk/Scanner.swift`: read-only scan (`fts_open`, `st_blocks`, no symlinks, no other
  volumes, hard links counted once). Special cases: per-model Ollama, per-repo Hugging Face,
  per-device simulators (via `simctl list -j`), Docker via `docker system df`.
- `Sources/DevDisk/History.swift`: `~/disk-report/sizes.csv` (`scanned_at,path,group,kind,bytes`).
  "Grew" means at least +10 MB and +2%.
- `Sources/DevDisk/Cleaner.swift`: runs the confirmed cleanup. Commands run via `zsh -f -c` with the
  user's login-shell PATH and stdin from /dev/null, and output streams to the page. Items without a
  command go to the Trash (only under ~). It re-sizes afterwards to report freed space; a run that
  frees under 1 MB shows "nothing to remove". The log is saved to `~/disk-report/cleanup-<time>.log`.
- `Web/`: `index.html`, `style.css`, `app.js`. Hand-written treemap, donut and bars, no frameworks.
- `scripts/make-icon.swift`: draws the app icon during the build.

## Rules that must hold

- **The scan is read-only and metadata-only.** Never open file contents. Never enter iCloud, cloud
  folders, the Photos library, other volumes, or anything that triggers a macOS permission prompt.
  Desktop/Documents/Downloads only when the user opted in (`protectedFolders` pref).
- **Nothing is deleted without the user confirming each item.** The page sends only item IDs. Commands
  come only from Swift's last scan result, never from the page.
- **A rule gets a `command` only if that command removes the whole folder it's sized by.** If the
  tool's command only cleans part of it, either point the rule at the subfolder it does clean, split
  the rule, or leave `command` nil (Move to Trash). Several bugs came from this mismatch
  (`gem cleanup`, `swift package purge-cache`, Poetry, Docker sizes).
- **Verify every clean command without side effects** before adding it: `--help`, a dry run
  (`brew cleanup -n`), reading the tool's source, or running it against a *copy* of the folder (e.g.
  `npm cache clean --force --cache <copy>`, `PIP_CACHE_DIR=<copy>`). Never run it on the real folder.
  Commands must be non-interactive (`-y`, `--force`, `-n`).
- **Name the binary when installs can coexist** (e.g. `"$HOME/miniconda3/bin/conda"`). The cleaner
  skips a command string it has already run.
- Sessions, models and Docker always go in `review`. Anything with user data goes in `review`.
- Each rule's `effect` says what happens if the folder is deleted, in one or two plain sentences.
  Mention partial cleanups. Use backticks for commands (the UI renders them as code).
- Shell-quote paths with `shq()`.

## Style

- Match the surrounding code: small functions, sparse comments that explain *why*.
- UI copy: plain, short and specific. Sentence case. No exclamation marks.
- Colors are tokens on `:root` with light and dark values. Each kind has a fixed color slot
  (javascript, python, apple, jvm, models, toolchains, sessions, docker).
- Commit messages explain why, not just what, and list how a fix was verified.
