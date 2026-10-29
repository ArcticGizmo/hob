# Ergonomics spike

A throwaway mock for getting a feel for typing `hob`, the shorter `h` prefix, and per-plugin shortcuts, and for seeing how jumping directories works given that a child process cannot move its parent shell. It needs nothing beyond PowerShell (5.1 or 7).

## Load it

In the repo root:

```powershell
. .\spikes\ergonomics\hob.ps1                  # hob + h + shortcuts
. .\spikes\ergonomics\hob.ps1 -Alias hh        # different prefix alias
. .\spikes\ergonomics\hob.ps1 -Alias ''        # no prefix alias
. .\spikes\ergonomics\hob.ps1 -NoShortcuts     # no per-plugin shortcuts
```

It only lasts for the current session. `h` normally means `Get-History`, and the loader tells you when it takes it over.

## Things to try

| Type | What happens |
|---|---|
| `hob` | Lists everything |
| `hob git`, `h docs`, `h temp` | Jump to a "flat" location from the `nav` plugin |
| `h spike` | Jump to the `spike` plugin's root (this repo) |
| `h spike docs` / `spike docs` | Same jump via prefix, then via the generated shortcut |
| `h sp pl` | Unique prefixes are accepted without Tab |
| `h d` | Ambiguous prefix (`docs`, `downloads`) is an error |
| `h back` | Return to where the last jump came from |
| `h naive temp` | A child `cmd.exe` changes its own directory; your shell does not move |
| `spike mkcd demo` | A plugin command that creates a folder and moves your shell into it |
| `spike stamp`, then `$env:HOB_STAMP` | A plugin command that sets an environment variable in your shell |
| `spike hello` | A plugin command that only prints |
| `h <Tab>`, `h spike <Tab>`, `spike m<Tab>` | Completion with descriptions. Ctrl+Space shows the menu |

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
| Jump (`hob git`, `h sp pl`) | 3–5 ms | 6–14 ms |
| Tab completion | 2–4 ms | 5–7 ms |
| Plugin command (`spike hello`, a `.cmd`) | 40–55 ms | 50–60 ms |

The same jumps through a Node child process took 175–300 ms.

## Known differences from the real thing

- Manifests are JSON because PowerShell parses it natively. E7 decides the real format.
- Only a PowerShell adapter exists. cmd and Git Bash cannot parse manifests themselves, so they will likely read a flat index the core generates (see E3).
- Demo commands are `.cmd` files only to avoid dependencies. A PowerShell-script command would either pay for a new PowerShell process (200 ms+) or run inside your shell, which is a trust decision still to make.
