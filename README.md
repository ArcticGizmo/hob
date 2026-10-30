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

> **Status: early.** hob is Windows-only for now, and what ships today is the ergonomics spike in [`spikes/ergonomics`](spikes/ergonomics). It works and is used daily, but names, file formats and the data folder may still change.

### At a glance

```powershell
hb to git            # jump to a place; prefixes work (hb to gi)
hb to                # pick from every place, ranked by where you go most
hb back              # return to where the last jump came from
hb recent            # places ranked by frecency
nav downloads        # a plugin's own shortcut: jump to one of its places
hob path docs        # print a folder instead of going there: code (hob path docs)
hob                  # list plugins and built-ins
```

- **Moves your actual shell**: no child process trying to `cd` for you. Jumps run inside your PowerShell or cmd session, so they take about 25 ms.
- **One short name**: `hob`, or `hb` for short, plus an optional shortcut per plugin.
- **A picker that learns**: type a few letters of a place's name, plugin or path. Places you visit often and recently float to the top.
- **Tab completion** in PowerShell, including in a brand-new window.
- **Plugins are just folders**: a `plugin.json` listing places and commands. Commands can be any script or program, and can ask hob to change your directory or set an environment variable when they finish.
- **No shell setup**: nothing goes in `$PROFILE`, `.bashrc` or cmd's AutoRun, and nothing runs when a terminal opens.

## How it works

The installer writes a folder of small commands, `hob.ps1`, `hob.cmd` and a bash script for each name, and adds that one folder to your **user** PATH. Each shell picks the file it runs natively:

| Shell | Runs | Why it can move your shell |
| --- | --- | --- |
| PowerShell 5.1 and 7 | `hob.ps1` | PowerShell runs a script found on PATH inside the calling session |
| cmd | `hob.cmd` | cmd runs a batch file inside the calling window |
| Git Bash | `hob` | It can't: bash runs it as a separate process, so you use `cd "$(hob path git)"` |

cmd has no completion, picker or history. Git Bash looks places up and runs plugin commands, but can't jump by itself.

A plugin command that isn't PowerShell runs as a normal child process. To move your shell, it writes a line like `cd C:\some\folder` to a temporary file hob gives it. hob then applies a fixed set of actions from that file (change directory, set or unset a variable, go back) and ignores anything else. Nothing in it is ever run as code.

The full tour, with timings for each shell, is in [`spikes/ergonomics/README.md`](spikes/ergonomics/README.md).

## Installing

### Windows

```powershell
irm https://raw.githubusercontent.com/ArcticGizmo/hob/main/install.ps1 | iex
```

That's the whole install. Then open a **new** terminal and type `hob`.

No admin rights: hob installs to `%LOCALAPPDATA%\Hob`, and its commands go in `%LOCALAPPDATA%\hob-spike\bin`, which is added to your user PATH. If Windows Terminal was already open, restart it once so new tabs see the PATH change.

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

Uninstall **hob** from Settings → Apps. That removes the commands folder from your PATH. Your settings, plugins and jump history in `%LOCALAPPDATA%\hob-spike` are left in place; delete that folder to remove them too.

If the PATH step ever goes wrong, `hob-cli setup` repeats it and `hob-cli setup --undo` reverses it. The previous PATH values are saved in `%LOCALAPPDATA%\hob-spike\path-backups`.

## Updating

```powershell
hob update            # download and install the latest release
hob update --check    # only say whether there is one
```

Updates replace `%LOCALAPPDATA%\Hob\current` and regenerate the commands. Nothing of yours lives there, so updates never touch your settings, plugins or history. You never need to run the install script again.

## Your own places and commands

hob ships with one plugin, `nav`, for everyday places (`home`, `docs`, `downloads`, `git`, `temp`). Add your own by creating a folder per plugin in `%LOCALAPPDATA%\hob-spike\plugins`, or in a git repo you list in your settings:

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

That gives you `hb to api`, `work web`, `work build`, and the same with tab completion. Changes are picked up on your next command, except in cmd, which needs `hob reindex`.

`%LOCALAPPDATA%\hob-spike\settings.json`, all keys optional:

```json
{
  "alias": "hb",
  "shortcuts": true,
  "pluginPaths": ["%USERPROFILE%\\git\\my-hob-plugins"],
  "roots": { "git": "D:\\src" }
}
```

Every jump is recorded in `%LOCALAPPDATA%\hob-spike\history.tsv` to rank the picker. Set `$env:HOB_NO_HISTORY = 1` to stop recording, or delete the file to start over.

## Building a release (maintainers)

Releases are made by pushing a version tag. GitHub Actions builds and publishes them.

1. Push a tag:
   ```
   git tag v0.2.0
   git push origin v0.2.0
   ```
2. [`release.yml`](.github/workflows/release.yml) runs [`build/pack.ps1`](build/pack.ps1) on Windows with the tag's version, then the `release` job collects every file into one folder, writes `SHA256SUMS.txt` over it, and publishes the GitHub release.

The version comes from the tag, so there is nothing to bump in the project files.

The release job fails rather than publish if two files share a name, or if `Hob-win-Setup.exe` is missing, because `install.ps1` finds that file by name. `SHA256SUMS.txt` is written from the exact files being uploaded, so it can't drift from what people download.

**What checksums do and don't buy.** They prove the installer you ran is the one that was published, catching truncated downloads, proxies rewriting the payload, and tampering in transit. They are *not* a signature: the checksums live on the same release as the installer, so anyone who could replace one could replace both. The installer and `hob-cli.exe` are not code-signed yet.

### Building locally

```powershell
.\build\pack.ps1 -Version 0.0.1 -Clean
```

This writes `Hob-win-Setup.exe` and the update feed to `artifacts\releases`. The `vpk` packaging tool is pinned in `dotnet-tools.json` and restored for you. `-Clean` starts the feed over, since vpk won't pack a version that isn't newer than one already there.

## Development

Requirements: .NET 10 SDK, and Windows PowerShell 5.1 and PowerShell 7 for testing.

To try hob from a checkout without building anything:

```powershell
.\spikes\ergonomics\install.ps1      # adds the checkout's commands to your user PATH
.\spikes\ergonomics\uninstall.ps1    # undo
```

| Path | What it is |
| --- | --- |
| `spikes/ergonomics/hob.psm1` | The core: plugin discovery, matching, picker, history, directives |
| `spikes/ergonomics/cmd`, `bash` | The cmd and Git Bash adapters |
| `spikes/ergonomics/templates` | The per-name scripts written into the commands folder |
| `src/Hob.Cli` | `hob-cli.exe`: Velopack's install, update and uninstall hooks, `setup` and `update` |
| `install.ps1` | The checksum-verifying web installer |
