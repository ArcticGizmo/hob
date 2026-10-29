# Ergonomics spike

A throwaway mock for getting a feel for typing `hob`, the short name `hb`, and per-plugin shortcuts, and for seeing how jumping directories works given that a child process cannot move its parent shell. It needs nothing beyond Windows itself: PowerShell (5.1 or 7) and cmd. Git Bash works in a reduced form.

## Install once

```powershell
.\spikes\ergonomics\install.ps1                  # hob, hb and plugin shortcuts
.\spikes\ergonomics\install.ps1 -Alias j         # a different short name
.\spikes\ergonomics\install.ps1 -NoShortcuts     # no per-plugin shortcuts like `spike`
.\spikes\ergonomics\install.ps1 -KeepPath        # write the commands but add the folder to PATH yourself
.\spikes\ergonomics\uninstall.ps1                # undo; add -History to delete your jump history too
```

The installer writes a folder of small commands to `%LOCALAPPDATA%\hob-spike\bin` and adds it to your user PATH. That is the only change outside hob's own folders. It never touches `$PROFILE`, `.bashrc` or cmd's AutoRun, and nothing has to run in each new terminal. New terminals pick it up straight away; Windows Terminal hands new tabs the environment it started with, so restart it once if a new tab cannot find `hob`.

### Why a folder of commands works without any setup

For each name (`hob`, `hb`, and one per plugin such as `spike`) the folder holds three files, and each shell picks its own:

| File | Used by | Why it can move the shell |
|---|---|---|
| `hob.ps1` | PowerShell, which prefers it over `hob.cmd` in the same folder | PowerShell runs a script found on PATH inside the calling session. Its completer is declared in the script, so the first Tab in a new window works |
| `hob.cmd` | cmd | cmd runs a batch file inside the calling window |
| `hob` | Git Bash | It cannot: Git Bash runs it as a separate process, so bash uses `cd "$(hob path git)"` |

`h` is not used because PowerShell's built-in `h` alias (`Get-History`) takes precedence over anything on PATH. The commands are regenerated whenever plugins or settings change, and names that would hide an existing command are skipped with a warning.

## Things to try

| Type | What happens |
|---|---|
| `hob` | Lists plugins and built-ins |
| `hb to` | Opens the picker over every place from every plugin (see below) |
| `hb to --list` | Prints the places instead. Also what `hb to` does when output is redirected |
| `hb to git`, `hb cd temp` | Jump to a place. `cd` is an alias of `to` |
| `hb to spike` | A plugin's root is a place named after the plugin |
| `hb to ergo`, `hb to erg` | Places from any plugin, by name or unique prefix |
| `hb to docs` | Ambiguous (`nav docs`, `spike docs`): opens the picker with `docs` already typed |
| `hb to zzz` | No match: opens the picker with `zzz` typed, so you can fix the query |
| `hb to spike docs`, `hb to sp pl` | Qualified by plugin, prefixes work for both words |
| `spike docs`, `hb spike docs` | Plugin-scoped jumps, via the generated shortcut or the short name |
| `hob path spike`, `code (hob path spike)` | Prints the folder instead of going there |
| `hb git` | Not a top-level name; the error suggests `hob to git` |
| `hb back` | Return to where the last jump came from |
| `hb recent` | Places ranked by frecency, with visit counts and when you last went there |
| `hb naive temp` | A child `cmd.exe` changes its own directory; your shell does not move |
| `spike mkcd demo` | A plugin command that creates a folder and moves your shell into it |
| `spike stamp`, then `$env:HOB_STAMP` | A plugin command that sets an environment variable in your shell |
| `spike hello` | A plugin command that only prints |
| `spike gitroot`, then `hb back` | A PowerShell plugin command: runs inside your session, so it moves the shell directly, and `back` still undoes it |
| `hb to <Tab>`, `hb to do<Tab>`, `spike <Tab>` | Completion. Shared names complete to their qualified form (`nav docs`). Ctrl+Space shows the menu |

### In cmd and Git Bash

cmd supports everything above except completion (that needs Clink), the picker, `recent`, `naive` and PowerShell plugin commands like `gitroot`. It records no history.

Git Bash cannot change directory from a command without a line in `.bashrc`, which hob does not write. So in bash:

```bash
cd "$(hob path git)"        # jump; prefixes and plugin-qualified names work
cd "$(hb path docs)"        # ambiguous: bash's numbered menu asks which one
spike hello                 # plugin commands run; if one asks to move or set a variable, hob says what it wanted
```

Anything that would have moved the shell (`hb to git`, `spike docs`, `hb back`) explains the `cd` form instead. There is no completion in bash.

Both read `%LOCALAPPDATA%\hob-spike\index.txt`, which `hob.psm1` writes whenever the manifests change. It lists every spelling hob accepts, already resolved, so the other shells look keys up instead of reimplementing the matching. If it is missing or older than a manifest, bash rebuilds it automatically by running PowerShell once; in cmd, run `hob reindex`. See `docs/experiments/03-directives-across-shells.md` for timings and the hostile-input results.

### The picker

```
to> docs
  nav docs       C:\Users\you\Documents
> spike docs     C:\Users\you\Documents\git\personal\hob\docs
  2/9   Up/Down move   Enter jump   Esc cancel
```

Type to filter: each space-separated word must appear in the place's name, plugin or path, so `sp pl` finds `spike plugins`. Places whose name starts with your first word rank first, then by frecency (below). Keys: Up/Down or Ctrl+P/Ctrl+N to move, PageUp/PageDown, Backspace, Ctrl+U to clear, Enter to jump, Esc or Ctrl+C to cancel. It draws under the prompt and erases itself afterwards, so only your command stays in the scrollback. It is plain PowerShell with no dependencies.

### Frecency

Every jump appends one line to `%LOCALAPPDATA%\hob-spike\history.tsv`, outside the repo: time, how you got there (`to`, `picker`, `direct` or `path`), the path, and for picker jumps the row you chose and what you had typed. Each visit scores by age, as zoxide does: 4 within the hour, 2 within the day, 0.5 within the week, 0.25 after that. The picker sorts by that score, so after a few days `hb to` then Enter usually lands where you meant.

The file is shared by PowerShell and Git Bash and re-read only when it changes, so a jump in one window shows up in the next picker you open anywhere. Set `$env:HOB_NO_HISTORY = 1` to stop recording. Delete the file to start over.

The picker rows are the raw material for E6: after a couple of weeks, the share of picker jumps on row 0 says how often the ranking already had the right place on top, and the log can be replayed against other formulas.

Top-level names are only built-ins and plugins, so a place can never clash with a command.

Locations come from `plugins/*/plugin.json`. Edits are picked up on the next command. Roots are `{home}`, `{temp}`, `{hob}` (this repo) and `{git}` (defaults to `~/Documents/git`). Override any of them in a gitignored `roots.local.json` next to `hob.psm1`, for example `{ "git": "D:/src" }`.

## How it works

Jumps never leave the shell in PowerShell or cmd. `hob.psm1` reads the manifests (cached until one changes), resolves the words and calls `Push-Location` itself. Starting even an empty process costs about 70 ms on this machine, so keeping the most common action in-process is what makes it fast. The module exports nothing: a global `hob` function would take precedence over `hob.ps1` on PATH, and with it the completer declared there.

Plugin commands written in PowerShell (`.ps1`) run inside your session, because plugins are trusted code and a new PowerShell process costs 200 ms or more. They can `Set-Location` or set variables directly; if one moves you, hob records where you were so `hob back` returns there. In bash and cmd they are refused with a message, since they would have to run in a separate PowerShell and could not move that shell anyway.

Every other plugin command is a separate program, so it cannot move the shell. It uses a directives file instead:

```
you type: spike mkcd demo
  │
  ├─ hob (in your shell) creates an empty temp file, sets $env:HOB_DIRECTIVES to its path
  │
  ├─ mkcd.cmd (child process) makes the folder and appends the line: cd C:\...\hob-spike\demo
  │
  └─ hob (in your shell) reads the file and applies known directives only:
       cd C:\abs\path   → Push-Location (so `hob back` can Pop-Location)
       env NAME=value   → set $env:NAME
       unset NAME       → remove $env:NAME
       back             → Pop-Location
     anything else is reported and ignored, then the file is deleted
```

One action per line, because cmd and bash can split that with builtins but cannot parse JSON. Nothing from the file is evaluated as code: `cd C:\; Remove-Item x` is just a path that does not exist. Names bash would execute (`PROMPT_COMMAND`, `PS1` and friends) are refused in every shell.

## Measured on this machine

| Action | PowerShell 5.1 | PowerShell 7 | cmd | Git Bash |
|---|---|---|---|---|
| First `hob` in a new window | ~430 ms | ~290 ms | ~19 ms | ~150 ms |
| Jump (`hb to git`) | 22–30 ms | 29–37 ms | ~19 ms | `hob path` ~150 ms |
| Tab completion | 15–17 ms | 17–19 ms | — | — |
| Plugin command (`spike hello`, a `.cmd`) | 40–55 ms | 50–60 ms | in-window `call` | ~85 ms |
| PowerShell plugin command (`spike gitroot`) | 14–20 ms | 22–26 ms | — | — |

About 10 ms of each PowerShell call is PowerShell finding and starting a script from PATH, the price of needing no setup. Git Bash spends about 140 ms just starting a bash process, which only a function defined in `.bashrc` would avoid. The same jumps through a Node child process took 175–300 ms.

## Known differences from the real thing

- Manifests are JSON because PowerShell parses it natively. E7 decides the real format.
- Demo commands are `.cmd` files only to avoid dependencies.
- The first call in each PowerShell window loads the module and all plugin manifests eagerly. A real core could load lazily.
