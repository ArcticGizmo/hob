# How hob works

hob has two halves. `hob-cli.exe` knows everything: settings, your places, plugins, matching, the picker, history and ranking, and the commands it puts on your PATH. A thin wrapper per shell (`hob.psm1`, `hob.cmd`, `hob.sh`) answers the most common requests from a lookup table the exe writes, and hands everything else to the exe.

The split exists because starting any process costs 50-100 ms on a machine running endpoint security, and a jump should feel instant. On the machine this was measured on, a jump answered by the wrapper takes 16-29 ms in PowerShell; anything that goes through the exe takes about 200 ms (see [Measured](#measured)).

## Install folder and data folder

| Folder | What's in it | Who changes it |
| --- | --- | --- |
| `%LOCALAPPDATA%\Hob\current` (or `artifacts\dev` in a checkout) | `hob-cli.exe`, `hob.psm1`, `cmd\hob.cmd`, `bash\hob.sh`, `templates\` | Replaced on every update |
| `%USERPROFILE%\.hob` (or `HOB_HOME`) | `settings.json`, `places.json`, `plugins\`, `bin\`, `index.txt`, `history.tsv`, `hob-cli.log`, `path-backups\` | Yours. Updates and uninstall leave it alone, except `bin\` and `index.txt`, which are generated |

`bin\` is the one folder on your user PATH. hob never touches `$PROFILE`, `.bashrc` or cmd's AutoRun, and nothing runs when a terminal opens.

## The commands on PATH

For each name (`hob`, the short name `hb`, and one per plugin such as `work`) the `bin` folder holds three files, and each shell picks its own:

| File | Used by | Why it can move the shell |
|---|---|---|
| `hob.ps1` | PowerShell, which prefers it over `hob.cmd` in the same folder | PowerShell runs a script found on PATH inside the calling session. Its completer is declared in the script, so the first Tab in a new window works |
| `hob.cmd` | cmd | cmd runs a batch file inside the calling window |
| `hob` | Git Bash | It cannot: Git Bash runs it as a separate process, so bash uses `cd "$(hob places git)"` |

The exe writes them from `templates\` whenever plugins or settings change. Names that would be hidden by something PowerShell or cmd resolves first (`h` is PowerShell's `Get-History` alias) or by another program on PATH are skipped with a warning.

## The index

`index.txt` lists every spelling the wrappers may answer without the exe, already resolved, one `kind|key|value` line each because cmd and bash can split that with builtins. Keys are lower-case.

| Kind | Key | Value | Used by |
|---|---|---|---|
| `to` | place query: `git`, `gi`, `work api`, `w a` | folder | `to`, `cd`, `places` (except `places add`, `rm` and `remove`) |
| `go` | plugin words: `work`, `wo api` | folder | plugin root and location jumps |
| `run` | plugin and command: `work build` | program, then the plugin folder | plugin commands with a single `run` entry |
| `top` | name | description | PowerShell completion |
| `sub` | plugin, or `places` | child, `place` or `command`, then detail | PowerShell completion |
| `tocomp` | completion text | folder | PowerShell completion |
| `watch` | file or folder | | staleness check |

Only definite hits are listed. Anything ambiguous, unknown or misspelled is not in the index, so the wrapper passes it to the exe, which prints the same error in every shell, or opens the picker.

The index is stale when it is missing, in an older format, or anything on its `watch` list (settings, places, plugin folders and manifests, the exe) is newer. The exe and the PowerShell and bash wrappers all apply that rule and rebuild through `hob-cli.exe index`. cmd cannot cheaply compare timestamps, so after editing a plugin by hand run `hob reindex` there, or any command that goes through the exe.

## Moving the shell: directives

A program cannot change its parent's directory, so the exe and plugin commands ask the wrapper to, through a file:

```
you type: hob to            (no place, so the wrapper hands it to the exe)
  │
  ├─ wrapper creates an empty temp file, sets HOB_DIRECTIVES to its path and HOB_SHELL to its shell
  │
  ├─ hob-cli.exe shows the picker on the console and appends:  cd C:\Users\you\Documents
  │
  └─ wrapper reads the file and applies known directives only:
       cd C:\abs\path   → Push-Location / pushd (so `hob back` can return)
       env NAME=value   → set the variable
       unset NAME       → remove it
       back             → Pop-Location / popd
     anything else is reported and ignored, then the file is deleted
```

Nothing from the file is evaluated as code: `cd C:\; Remove-Item x` is just a path that does not exist. Names bash would execute (`PROMPT_COMMAND`, `PS1` and friends) are refused in every shell. In Git Bash the wrapper reports what a directive wanted instead, for example the `cd` to type.

## Plugin commands

The wrapper runs them itself from the index, with `HOB_DIRECTIVES` and `HOB_PLUGIN_DIR` set:

- `.ps1` commands run inside your PowerShell session, because plugins are trusted code and a new PowerShell costs 200 ms or more. They can `Set-Location` directly; hob records where you were so `hob back` returns there. cmd and Git Bash run them in a child `powershell.exe -NoProfile -File`, where they can still use directives.
- Anything else runs as a child process.

A command whose `run` has more than one entry (`["node", "{plugin}\\x.js"]`) is run by the exe, since cmd cannot split it.

## The picker

`hob to` with no place, or `hob to` or `hob places` with one that matches several, opens the picker when there is a console. A place that matches nothing is an error rather than a search, so a typo never looks like one:

```
to> docs
  docs           C:\Users\you\Documents
> work docs      C:\work\docs
  2/9   Up/Down move   Enter jump   Esc cancel
```

Type to filter: each space-separated word must appear in the place's name, plugin or path. Places whose name starts with your first word rank first, then by frecency. Keys: Up/Down or Ctrl+P/Ctrl+N, PageUp/PageDown, Backspace, Ctrl+U to clear, Enter to jump, Esc or Ctrl+C to cancel.

The exe draws it straight onto the console (`CONOUT$`, VT sequences), never on stdout, so it works in PowerShell, cmd, and Git Bash inside `cd "$(hob places d)"`. It draws under the prompt and erases itself afterwards. Without a console (input redirected, or Git Bash under mintty) hob prints the candidates instead.

## Places

Your places live in `places.json`:

```json
{
  "docs": "{home}/Documents",
  "work": "D:\\src\\work"
}
```

hob writes it once, the first time it runs, with `home`, `docs`, `downloads`, `git` and `temp`. After that it is yours: `hob places add`, `hob places rm` and hand edits all stick, including deleting the starter places. `add`, `rm` and `remove` can't be place names, since `hob places add` already means something. Values can use roots (`{home}`, `{temp}`, `{git}`, and any in settings) and `%VARIABLES%`.

When one of your places has the same name as a plugin's, yours wins; the plugin's is still reachable as `hob to <plugin> <name>`.

## Frecency

Every jump appends one line to `history.tsv`: time, how you got there (`to`, `direct`, `picker`, or `path` when `hob places` printed it), the path, and for picker jumps the row you chose and what you had typed. Each visit scores by age, as zoxide does: 4 within the hour, 2 within the day, 0.5 within the week, 0.25 after that. cmd jumps answered from the index are not recorded, because batch has no cheap way to get a timestamp. Set `HOB_NO_HISTORY=1` to stop recording.

The picker rows are the raw material for E6: the share of picker jumps on row 0 says how often the ranking already had the right place on top.

## Measured

On the development machine (CrowdStrike Falcon and Defender), 2026-10-30:

| Action | PowerShell 5.1 | PowerShell 7 | cmd | Git Bash |
|---|---|---|---|---|
| Jump answered by the wrapper | ~25-29 ms | ~16 ms | in-window | `hob places` ≈ bash startup (~280 ms in a sandbox here) |
| Anything through the exe | ~210-250 ms | ~210 ms | ~200 ms | + bash startup |

The exe's time is almost all process and .NET runtime startup; loading settings, places and plugins is a few milliseconds. `build\pack.ps1 -Aot` builds it with Native AOT, which should bring it close to a native program's ~100 ms, but needs the MSVC build tools.

## Testing without touching your machine

```powershell
$env:HOB_HOME = "$env:TEMP\hob-test"          # scratch data folder
$env:HOB_PATH_KEY = 'Software\hob-test'       # PATH edits go to a throwaway registry key
.\build\dev.ps1
.\artifacts\dev\hob-cli.exe setup
$env:PATH = "$env:HOB_HOME\bin;$env:PATH"
```

Delete `HKCU\Software\hob-test` and the scratch folder afterwards. `tests\Hob.Cli.Tests` covers matching, places, the index and the commands; `dotnet test tests\Hob.Cli.Tests` runs it.
