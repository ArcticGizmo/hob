# Ergonomics spike

A throwaway mock for getting a feel for typing `hob`, the shorter `h` prefix, and per-plugin shortcuts, and for seeing how jumping directories works given that a child process cannot move its parent shell. It needs nothing beyond PowerShell (5.1 or 7).

## Load it

In the repo root:

```powershell
. .\spikes\ergonomics\hob.ps1                  # hob + h + shortcuts
. .\spikes\ergonomics\hob.ps1 -Alias hh        # different prefix alias
. .\spikes\ergonomics\hob.ps1 -Alias ''        # no prefix alias
. .\spikes\ergonomics\hob.ps1 -NoShortcuts     # no per-plugin shortcuts
. .\spikes\ergonomics\hob.ps1 -FlatPlaces      # also allow `h git` without `to`
```

It only lasts for the current session. `h` normally means `Get-History`, and the loader tells you when it takes it over.

## Things to try

| Type | What happens |
|---|---|
| `hob` | Lists plugins and built-ins |
| `h to` | Opens the picker over every place from every plugin (see below) |
| `h to --list` | Prints the places instead. Also what `h to` does when output is redirected |
| `h to git`, `h cd temp` | Jump to a place. `cd` is an alias of `to` |
| `h to spike` | A plugin's root is a place named after the plugin |
| `h to ergo`, `h to erg` | Places from any plugin, by name or unique prefix |
| `h to docs` | Ambiguous (`nav docs`, `spike docs`): opens the picker with `docs` already typed |
| `h to zzz` | No match: opens the picker with `zzz` typed, so you can fix the query |
| `h to spike docs`, `h to sp pl` | Qualified by plugin, prefixes work for both words |
| `h spike docs` / `spike docs` | Plugin-scoped jumps still work, via prefix or generated shortcut |
| `h git` | Not a top-level name; the error suggests `h to git` (unless loaded with `-FlatPlaces`) |
| `h back` | Return to where the last jump came from |
| `h recent` | Places ranked by frecency, with visit counts and when you last went there |
| `h naive temp` | A child `cmd.exe` changes its own directory; your shell does not move |
| `spike mkcd demo` | A plugin command that creates a folder and moves your shell into it |
| `spike stamp`, then `$env:HOB_STAMP` | A plugin command that sets an environment variable in your shell |
| `spike hello` | A plugin command that only prints |
| `h to <Tab>`, `h to do<Tab>`, `h to spike <Tab>` | Place completion. Shared names complete to their qualified form (`nav docs`). Ctrl+Space shows the menu |

### The picker

```
to> docs
  nav docs       C:\Users\you\Documents
> spike docs     C:\Users\you\Documents\git\personal\hob\docs
  2/9   Up/Down move   Enter jump   Esc cancel
```

Type to filter: each space-separated word must appear in the place's name, plugin or path, so `sp pl` finds `spike plugins`. Places whose name starts with your first word rank first, then by frecency (below). Keys: Up/Down or Ctrl+P/Ctrl+N to move, PageUp/PageDown, Backspace, Ctrl+U to clear, Enter to jump, Esc or Ctrl+C to cancel. It draws under the prompt and erases itself afterwards, so only your command stays in the scrollback. It is plain PowerShell with no dependencies.

### Frecency

Every jump appends one line to `%LOCALAPPDATA%\hob-spike\history.tsv`, outside the repo: time, how you got there (`to`, `picker` or `direct`), the path, and for picker jumps the row you chose and what you had typed. Each visit scores by age, as zoxide does: 4 within the hour, 2 within the day, 0.5 within the week, 0.25 after that. The picker sorts by that score, so after a few days `h to` then Enter usually lands where you meant.

The file is shared by every shell and re-read only when it changes, so a jump in one window shows up in the next picker you open anywhere. Set `$env:HOB_NO_HISTORY = 1` to stop recording, or `$env:HOB_SPIKE_HISTORY` to use a different file. Delete the file to start over.

The picker rows are the raw material for E6: after a couple of weeks, the share of picker jumps on row 0 says how often the ranking already had the right place on top, and the log can be replayed against other formulas.

Top-level names are only built-ins and plugins, so a place can never clash with a command. `-FlatPlaces` puts places back at the top level when their name is unique and does not clash, and warns about the rest.

Locations come from `plugins/*/plugin.json`. Edits are picked up on the next command. Roots are `{home}`, `{temp}`, `{hob}` (this repo) and `{git}` (defaults to `~/Documents/git`). Override any of them in a gitignored `roots.local.json` next to `hob.psm1`, for example `{ "git": "D:/src" }`.

## How it works

Jumps never leave the shell. `hob.psm1` reads the manifests (cached until one changes), resolves the words and calls `Push-Location` itself. Starting even an empty process costs about 70 ms on this machine, so keeping the most common action in-process is what makes it fast.

Plugin commands are separate programs, so they cannot move the shell. They use a directives file instead:

```
you type: spike mkcd demo
  │
  ├─ hob (in your shell) creates an empty temp file, sets $env:HOB_DIRECTIVES to its path
  │
  ├─ mkcd.cmd (child process) makes the folder and appends {"cd":"...\\hob-spike\\demo"}
  │
  └─ hob (in your shell) reads the file and applies known directives only:
       cd    → Push-Location (so `h back` can Pop-Location)
       env   → set or clear $env:NAME (names validated)
       back  → Pop-Location
     anything else is reported and ignored, then the file is deleted
```

Nothing from the file is evaluated as code. A directive like `{"cd": "C:\\; Remove-Item x"}` is just a path that does not exist.

## Measured on this machine

| Action | PowerShell 5.1 | PowerShell 7 |
|---|---|---|
| Jump (`h to git`, `h to sp pl`) | 4–18 ms | 6–19 ms |
| Tab completion | 3–20 ms | 5–9 ms |
| Plugin command (`spike hello`, a `.cmd`) | 40–55 ms | 50–60 ms |

The same jumps through a Node child process took 175–300 ms.

## Known differences from the real thing

- Manifests are JSON because PowerShell parses it natively. E7 decides the real format.
- Only a PowerShell adapter exists. cmd and Git Bash cannot parse manifests themselves, so they will likely read a flat index the core generates (see E3).
- Demo commands are `.cmd` files only to avoid dependencies. A PowerShell-script command would either pay for a new PowerShell process (200 ms+) or run inside your shell, which is a trust decision still to make.
