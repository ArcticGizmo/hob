<h1 align="center">hob</h1>
<p align="center">
 <img src="./hob.svg" width="150" />
</p>

<p align="center">
<strong>Jump anywhere and run your everyday commands, the same way in every Windows shell.</strong>
</p>

<br>

A hob is a household spirit from English folklore that quietly does the chores. `hob` does the terminal chores: getting you to the folder you meant, running the things you always run, and doing it the same way in **PowerShell, cmd and Git Bash**.

It replaces the folder of batch files on PATH that most of us end up with. Places and commands live in small plugin folders you can keep in git, with tab completion, a picker, and a ranking that learns where you actually go.

Already know you want it? [Skip the details and install it ▼](#installing)

> **Status: early.** hob is Windows-only for now. It works and is used daily, but names, file formats and the data folder may still change.

### At a glance

```powershell
hb to git                 # jump to a place; prefixes work (hb to gi)
hb to                     # pick from every place, ranked by where you go most
hb to --add work          # make the folder you're in a place called work
hb to --add work D:\src   # ...or point it somewhere else; --rm work removes it
hb back                   # return to where the last jump came from
hb recent                 # places ranked by frecency
hob path docs             # print a folder instead of going there: code (hob path docs)
hob                       # everything hob knows; hob --version for the version
```

- **Moves your actual shell**: no child process trying to `cd` for you. Jumps run inside your PowerShell or cmd session, so they take about 25 ms.
- **The same in every shell**: the picker, `recent`, place management and every error message work identically in PowerShell, cmd and Git Bash.
- **One short name**: `hob`, or `hb` for short, plus an optional shortcut per plugin.
- **A picker that learns**: type a few letters of a place's name, plugin or path. Places you visit often and recently float to the top.
- **Tab completion** in PowerShell, including in a brand-new window.
- **Plugins are just folders**: a `plugin.json` listing places and commands. Commands can be any script or program, and can ask hob to change your directory or set an environment variable when they finish.
- **No shell setup**: nothing goes in `$PROFILE`, `.bashrc` or cmd's AutoRun, and nothing runs when a terminal opens.

## How it works

`hob-cli.exe` holds all of hob's logic. The installer puts a folder of small commands on your **user** PATH, `hob.ps1`, `hob.cmd` and a bash script for each name, and each shell picks the file it runs natively:

| Shell | Runs | Why it can move your shell |
| --- | --- | --- |
| PowerShell 5.1 and 7 | `hob.ps1` | PowerShell runs a script found on PATH inside the calling session |
| cmd | `hob.cmd` | cmd runs a batch file inside the calling window |
| Git Bash | `hob` | It can't: bash runs it as a separate process, so you use `cd "$(hob path git)"` |

Those scripts answer jumps from a lookup table the exe writes, so a jump never starts a process. Everything else goes to the exe, which asks the script to move your shell by writing a line like `cd C:\some\folder` to a temporary file. The script applies a fixed set of actions from that file (change directory, set or unset a variable, go back) and ignores anything else. Nothing in it is ever run as code. Plugin commands use the same file.

Tab completion is PowerShell-only, and cmd doesn't record jumps it answers itself in the history. The full tour, with timings for each shell, is in [`docs/how-it-works.md`](docs/how-it-works.md).

## Installing

### Windows

```powershell
irm https://raw.githubusercontent.com/ArcticGizmo/hob/main/install.ps1 | iex
```

That's the whole install. Then open a **new** terminal and type `hob`.

No admin rights: hob installs to `%LOCALAPPDATA%\Hob`, and its commands go in `%USERPROFILE%\.hob\bin`, which is added to your user PATH. If Windows Terminal was already open, restart it once so new tabs see the PATH change.

What the script does, in order: finds the release, downloads `SHA256SUMS.txt` and `Hob-win-Setup.exe`, **checks the installer against the checksums and deletes it rather than run it if they don't match**, runs the installer, then runs `hob-cli setup` so you can see the PATH result. It's [`install.ps1`](install.ps1) in this repo; read it before piping it into your shell, as you should with any installer.

Install a specific version instead of the latest:

```powershell
$env:HOB_VERSION = '0.1.0'; irm https://raw.githubusercontent.com/ArcticGizmo/hob/main/install.ps1 | iex
```

PowerShell doesn't tag what it downloads with the mark-of-the-web, so this route skips the **"Windows protected your PC"** SmartScreen dialog.

### Windows: if piping into `iex` is blocked

Some endpoint protection products block `irm | iex` outright. The same script works as a file, with ordinary parameters:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/ArcticGizmo/hob/main/install.ps1 -OutFile install-hob.ps1
.\install-hob.ps1                  # or -Version 0.1.0
```

This needs an execution policy of `RemoteSigned` or looser, which is the default on most developer machines.

### Windows: installer by hand

Download `Hob-win-Setup.exe` from the [latest release](https://github.com/ArcticGizmo/hob/releases/latest) and run it. You get the same install and the same updates.

A browser download *is* tagged with the mark-of-the-web, so SmartScreen shows **"Windows protected your PC"**. Click **More info → Run anyway**, or use the script above. To check the download against the release's `SHA256SUMS.txt` yourself:

```powershell
$want = (Select-String -Path SHA256SUMS.txt -Pattern 'Hob-win-Setup.exe').Line.Split()[0]
(Get-FileHash Hob-win-Setup.exe -Algorithm SHA256).Hash -eq $want   # True
```

### Uninstalling

Uninstall **hob** from Settings → Apps. That removes the commands folder from your PATH. Your settings, plugins and jump history in `%USERPROFILE%\.hob` are left in place; delete that folder to remove them too.

If the PATH step ever goes wrong, `hob-cli setup` repeats it and `hob-cli setup --undo` reverses it. The previous PATH values are saved in `%USERPROFILE%\.hob\path-backups`.

## Updating

```powershell
hob update            # download and install the latest release
hob update --check    # only say whether there is one
```

Updates replace `%LOCALAPPDATA%\Hob\current` and regenerate the commands. Nothing of yours lives there, so updates never touch your settings, places, plugins or history. You never need to run the install script again.

## Your own places

```powershell
hob to --add work            # the folder you're in
hob to --add work D:\src     # a folder by path; using a name you already have updates it
hob to --rm work
hob to --list
```

They live in `%USERPROFILE%\.hob\places.json`, which you can also edit by hand. The first time hob runs it fills that file with a few starter places, `home`, `docs`, `downloads`, `git` and `temp`, and never adds them again, so remove any you don't want.

## Plugins

For a set of places and commands you want to share or keep in git, create a folder per plugin in `%USERPROFILE%\.hob\plugins`, or in a git repo you list in your settings:

```json
{
  "name": "work",
  "description": "Work repos",
  "root": "{git}/work",
  "locations": {
    "api": "backend/api",
    "web": "frontend"
  },
  "commands": {
    "build": {
      "description": "Build everything",
      "run": ["{plugin}\\commands\\build.cmd"]
    }
  }
}
```

That gives you `hb to api`, `work web`, `work build`, and the same with tab completion. If one of your own places has the same name as a plugin's, yours wins and the plugin's is `hb to work <name>`. Changes are picked up on your next command, except in cmd, which needs `hob reindex`. [`examples/plugins/demo`](examples/plugins/demo) shows every kind of command.

`%USERPROFILE%\.hob\settings.json`, all keys optional:

```json
{
  "alias": "hb",
  "shortcuts": true,
  "pluginPaths": ["%USERPROFILE%\\git\\my-hob-plugins"],
  "roots": { "git": "D:\\src" }
}
```

Every jump is recorded in `%USERPROFILE%\.hob\history.tsv` to rank the picker. Set `$env:HOB_NO_HISTORY = 1` to stop recording, or delete the file to start over.

## Building a release (maintainers)

Releases are made by pushing a version tag. GitHub Actions builds and publishes them.

1. Push a tag:
   ```
   git tag v0.2.0
   git push origin v0.2.0
   ```
2. [`release.yml`](.github/workflows/release.yml) runs [`build/pack.ps1`](build/pack.ps1) on Windows with the tag's version, then the `release` job collects every file into one folder, writes `SHA256SUMS.txt` over it, and publishes the GitHub release.

The version comes from the tag, so there is nothing to bump in the project files. Each release gets a section in [`CHANGELOG.md`](CHANGELOG.md). In Claude Code, `/bump-version` writes the next section from the commits since the last tag, and `/release-next-version` packs locally, PRs and squash-merges the branch, tags `main` with the version from that section, and watches the release build.

The release job fails rather than publish if two files share a name, or if `Hob-win-Setup.exe` is missing, because `install.ps1` finds that file by name. `SHA256SUMS.txt` is written from the exact files being uploaded, so it can't drift from what people download.

**What checksums do and don't buy.** They prove the installer you ran is the one that was published, catching truncated downloads, proxies rewriting the payload, and tampering in transit. They are *not* a signature: the checksums live on the same release as the installer, so anyone who could replace one could replace both. The installer and `hob-cli.exe` are not code-signed yet.

### Building locally

```powershell
.\build\pack.ps1 -Version 0.0.1 -Clean
```

This writes `Hob-win-Setup.exe` and the update feed to `artifacts\releases`. The `vpk` packaging tool is pinned in `dotnet-tools.json` and restored for you. `-Clean` starts the feed over, since vpk won't pack a version that isn't newer than one already there. `-Aot` builds `hob-cli.exe` with Native AOT for faster startup; it needs the MSVC build tools.

## Development

Requirements: .NET 10 SDK, and Windows PowerShell 5.1 and PowerShell 7 for testing.

To run hob from a checkout:

```powershell
.\build\dev.ps1 -Setup                       # builds into artifacts\dev and puts its commands on your user PATH
.\artifacts\dev\hob-cli.exe setup --undo     # undo
dotnet test tests\Hob.Cli.Tests              # unit tests
```

Rerun `.\build\dev.ps1` after changing the exe or the shell scripts. To try it without touching your real PATH or data folder, see [Testing without touching your machine](docs/how-it-works.md#testing-without-touching-your-machine).

| Path | What it is |
| --- | --- |
| `src/Hob.Cli` | `hob-cli.exe`: everything hob knows, plus Velopack's install, update and uninstall hooks |
| `shell/hob.psm1`, `shell/cmd`, `shell/bash` | The PowerShell, cmd and Git Bash wrappers: answer jumps from the index, hand the rest to the exe |
| `shell/templates` | The per-name scripts written into the commands folder |
| `tests/Hob.Cli.Tests` | Unit tests |
| `examples/plugins` | A demo plugin with one of each kind of command; add the folder to `pluginPaths` to try it |
| `build` | `pack.ps1` (release), `dev.ps1` (checkout build) |
| `install.ps1` | The checksum-verifying web installer |
