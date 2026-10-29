# E3 — Directives across shells

| | |
|---|---|
| Date | 2026-10-29 |
| Code | `spikes/ergonomics` (`hob.psm1`, `bash/hob.sh`, `cmd/hob.cmd`) |
| Shells | Windows PowerShell 5.1, PowerShell 7.6, Git Bash (bash 5.3), cmd |
| Result | **Pass**, with a changed design: line-based directives instead of JSON, and a generated index for cmd and bash |

## Question

Can PowerShell 7, cmd and Git Bash all apply `cd` and environment changes from a structured file without any eval, while refusing malformed and hostile input?

## What changed from the scope

1. **Directives are one action per line, not JSON.** cmd and bash have no JSON parser, and shelling out to one costs a process launch (~70 ms on this machine). The format is now:

   ```
   cd C:\absolute\path
   env NAME=value
   unset NAME
   back
   ```

   Each shell splits the verb from the value with builtins. Values cannot contain newlines. cmd additionally refuses any line containing a double quote, which no legitimate path contains.

2. **Jumps do not use directives at all in PowerShell and bash.** Both resolve the place themselves and call `Push-Location`/`pushd`. Only plugin commands, which are separate processes, use the directives file.

3. **cmd and bash read a generated index.** `hob.psm1` writes `%LOCALAPPDATA%\hob-spike\index.txt` whenever the manifests change: every accepted spelling (prefixes, plugin-qualified forms, ambiguous keys with their candidates) already resolved, using the same functions as the PowerShell path. cmd and bash only look keys up, so the matching rules cannot drift between shells. If the index is missing or a manifest is newer, they rebuild it by running PowerShell once.

## Results

| | PowerShell 5.1 | PowerShell 7 | Git Bash | cmd |
|---|---|---|---|---|
| Jump | 3–5 ms | 6–14 ms | ~4 ms | ~19 ms |
| Tab completion | 2–4 ms | 5–9 ms | ~3 ms | none (no Clink) |
| Plugin command (`.cmd`) | 40–55 ms | 50–60 ms | ~85 ms | in-process `call` |
| Picker | inline, type to filter | same | `select` numbered menu | list only |
| History recorded | yes | yes | yes | no |

All hostile lines below were refused or applied as inert data in every shell, and no injection marker file was ever created:

- `cd C:\Windows & type nul > marker`, `cd C:\Windows" & ... & "`, `cd relative`, `cd -1`
- `env X=1 & type nul > marker` (cmd refuses: quotes; others store the literal value)
- `env Z=) & type nul > marker & (` stored literally
- `env W=a!b^c %PATH% & | > < ) (` stored literally, with no expansion of `%PATH%` or `!PATH!`
- `env PROMPT_COMMAND=calc`, `env ps1=$(calc)`, `unset IFS` refused
- `env BAD NAME=x`, `env ;X=1`, `env 1X=y`, `env =nothing`, `env NOEQUALS`, `back extra`, `rm -rf /`, JSON lines refused

## Findings worth keeping

- **Some environment variables are code in bash.** `PROMPT_COMMAND` runs before every prompt, `PS1` undergoes command substitution, `BASH_ENV` is sourced by child shells. Setting any of these from a directive would be eval by another name. All three adapters refuse `PROMPT_COMMAND`, `PS0`–`PS4`, `ENV`, `BASH_ENV`, `BASH_FUNC_*`, `BASHOPTS`, `SHELLOPTS` and `IFS`, case-insensitively, so behaviour is identical everywhere.
- **cmd batch files need CRLF line endings.** With LF endings cmd miscounts offsets, so `goto` and `call :label` land on the wrong line and the script silently runs the wrong code. `.gitattributes` now forces CRLF for `*.cmd` and `*.bat`.
- **cmd re-reads FOR variables when delayed expansion is on.** `!` and `^` inside data are processed, so `!PATH!` in a value expands. Directives are therefore split while delayed expansion is off, inspected with it on, and only accepted when the parts rebuild the original line exactly.
- **A quote inside an IF unbalances cmd's quote tracking**, because quotes are counted before variables expand. Strip quotes in a `SET "..."` statement first, which only looks at the last quote on the line.
- **Substitution on an undefined cmd variable returns the pattern text** (`!rest:p=!` gives `p=`). The character-whitelist check keeps a sentinel in the variable so it never becomes undefined.
- **Applying in cmd happens after `endlocal`**, through FOR variables, which cmd never re-parses for `& | > %`. A batch file runs inside the caller's cmd.exe, so this is how it moves the caller at all.
- **Windows PowerShell 5.1 drops `.Count` on a single `[pscustomobject]`** returned from a function. Wrap calls in `@()`.

## Open points

- cmd index lookups scan the file, so cost grows with the number of places. At a few thousand lines it will approach the 100 ms budget; splitting the index by kind, or one file per lookup type, would fix it.
- cmd does not record history (no cheap clock in .NET ticks) and has no picker beyond a list.
- cmd needs `chcp 65001` for non-ASCII paths in the index; not tested.
- The index is rebuilt by PowerShell. If the real core becomes a compiled executable (E1), it would write the index instead and PowerShell would read it too.
