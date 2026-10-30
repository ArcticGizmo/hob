# Plan: move hob's logic into the exe

Branch `feat/exe-core`. Started 2026-10-30 from user feedback on v0.1.1.

## Feedback being addressed

| # | Feedback | Resolution |
|---|---|---|
| 1 | `hob` / `hb` alone says "ambiguous" in PowerShell | Splatting `$null` passes one `$null` argument in PS 5.1 and 7, which became `''` and prefix-matched every built-in. The wrapper drops empty words |
| 2 | `hob list` is redundant with `hob` | Removed. `hob`, `hob --help` and `hob -h` list everything |
| 3 | No `--version` | `hob --version` / `hob -v` |
| 4 | `to` and `cd` on separate lines | Listed once as `to, cd` |
| 5 | Most commands are PowerShell-only | All logic moves into `hob-cli.exe`, so every shell gets the same picker, `recent`, place management and errors |
| 6 | `hob nav` is redundant with `hob to` | The `nav` plugin is gone; its places are seeded into your own place list |
| 7 | No way to add/remove/tweak `to` targets | `hob to --add <name> [path]`, `hob to --rm <name>`, stored in `%USERPROFILE%\.hob\places.json` |
| 8 | Built-in places should be seeded, not maintained | `places.json` is created once with home, docs, downloads, git and temp; after that it is yours, and deleting entries sticks |
| - | `hob naive` | Removed (spike demo) |

## Architecture

Every process start costs 50-100 ms on this EDR-scanned machine (measured: empty `cmd.exe` 40-58 ms, `where.exe` 93-113 ms, current `hob-cli.exe` 340-380 ms compressed / 173-203 ms uncompressed). A jump today is ~25 ms in-process. So:

- **`hob-cli.exe` owns all logic**: settings, plugins, places, matching, listing, picker, recent, history ranking, version, writing the index and the PATH commands, update, setup. One C# implementation with unit tests.
- **Each shell wrapper keeps one fast path**: it looks the words up in the index the exe writes. A definite hit (a place jump, a plugin location, a plugin command, `back`) is handled in the shell with no process start. Anything else, including every error, goes to the exe, so messages are identical everywhere.
- The exe talks back through the existing directives file (`cd`, `env`, `unset`, `back`), so it can move PowerShell and cmd. For Git Bash it prints `/c/...` paths and `cd "$(hob path x)"` hints.
- The picker is drawn by the exe on the console itself (`CONOUT$`, VT sequences), so it works in PowerShell, cmd and Git Bash in Windows Terminal, including inside `cd "$(hob path)"`, where stdout is captured. Under mintty there is no console, so it is skipped.
- Plugin commands are still run by the wrapper. `.ps1` commands run in-session in PowerShell; cmd and bash now run them in a child `powershell.exe` instead of refusing.
- The exe rebuilds the index whenever it runs and finds it stale. PowerShell and bash also check the index's watch list on every call; cmd needs `hob reindex` after hand-editing plugins (place edits go through the exe, which rewrites it).

### Index (`%USERPROFILE%\.hob\index.txt`), `kind|key|value[|extra]`, keys lower-case

| Kind | Key | Value | Used by |
|---|---|---|---|
| `to` | place query (`git`, `gi`, `demo docs`, `de d`) | folder | `to` / `cd` / `path` fast path |
| `go` | plugin words (`demo`, `de docs`) | folder | plugin root / location jump |
| `run` | plugin + command (`demo hello`) | program, then plugin folder | plugin command |
| `top` | name | description | PowerShell completion |
| `sub` | plugin | child, then description | PowerShell completion |
| `tocomp` | completion text | folder | PowerShell completion |
| `watch` | file or folder | | staleness check |

### Data folder

`%USERPROFILE%\.hob`, or `HOB_HOME` for tests: `settings.json`, `places.json`, `plugins\`, `bin\`, `index.txt`, `history.tsv`. `HOB_PATH_KEY` still redirects PATH edits to a throwaway registry key. The `HOB_SPIKE_*` variables are gone.

## Layout

```
src/Hob.Cli/          the exe
tests/Hob.Cli.Tests/  xunit
shell/                hob.psm1, cmd/hob.cmd, bash/hob.sh, templates/  (copied next to the exe)
examples/plugins/     the `demo` plugin (not shipped; add to pluginPaths)
build/pack.ps1        release; build/dev.ps1 stages a checkout build to artifacts/dev
```

The install folder layout does not change, so Velopack updates from 0.1.x keep working: `hob-cli.exe`, `hob.psm1`, `cmd\hob.cmd`, `bash\hob.sh`, `templates\`.

## Steps

1. Plan (this file).
2. C# core: paths, settings, roots, plugins, places store, model, matching, index writer, history and frecency, listing, recent, version, directives, bin writer (incl. plugin shortcuts and name-clash checks), picker.
3. Wrappers: rewrite `hob.psm1` as a thin index reader; slim `hob.cmd` and `hob.sh` to fast path + hand-off.
4. Hooks/setup build the full bin (plugin shortcuts too) instead of deferring to PowerShell.
5. Tests: unit tests for matching, places, index, settings; end-to-end runs in PS 5.1, PS 7, cmd and Git Bash against a scratch `HOB_HOME`.
6. Startup: drop single-file compression; measure; Native AOT is opt-in (`pack.ps1 -Aot`) because this machine has no MSVC. The project is marked AOT-compatible so the analyzers catch problems locally.
7. Docs: README, how-it-works, CHANGELOG `[Unreleased]`.

## Status (2026-10-30)

Steps 1-7 done. Verified end to end against a scratch `HOB_HOME` in PS 5.1, PS 7, cmd and Git Bash; 32 unit tests pass; `pack.ps1` builds and the release exe runs.

Not yet verified:

- The picker on a real console. Unit-tested with a fake terminal only; needs a hand test in Windows Terminal (PowerShell, cmd, Git Bash inside `cd "$(hob path)"`) and conhost.
- A Velopack update from 0.1.1 to this build (`hob update`): the update hook should rewrite `bin\`, drop the `nav` shortcut and seed `places.json`.
- `pack.ps1 -Aot` (no MSVC here). The exe takes ~200-250 ms to start without it.

## Not doing (yet)

- cmd history recording (no cheap timestamp in batch).
- Completion in cmd/bash (needs Clink / `.bashrc`).
- Turning AOT on in CI by default until it has been built once there.
