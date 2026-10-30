# Changelog

All notable changes to hob are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

- hob's brain moved into `hob-cli.exe`; the shell scripts now only do the jumping, which is the bit they're good at
- The picker, `recent` and every error message now work the same in cmd and Git Bash as in PowerShell
- Your own places: `hob to --add <name> [folder]`, `hob to --rm <name>`, kept in `%USERPROFILE%\.hob\places.json`
- The `nav` plugin is gone; its places are now starter places you're free to delete (they won't come back)
- `hob --version` / `hob -v`, and `hob --help` / `hob -h`
- `hob` and `hb` on their own no longer claim to be ambiguous in PowerShell
- `hob list` removed, since `hob` already says everything; `hob naive` retired with honours
- `to, cd` listed on one line, as befits two names for one thing
- PowerShell plugin commands run in cmd and Git Bash too (in a child PowerShell, so they can't move your shell)
- `HOB_HOME` moves the whole data folder, replacing four separate override variables

---

## [v0.1.1] - 2026-10-30

- One-line install with `irm | iex` (read it first; we did)
- Installer down from 40.6 MB to 16.7 MB
- Data moved to `%USERPROFILE%\.hob`; the 0.1.0 data folder is not migrated (it knew the risks)
- hob has an icon in Settings > Apps
- A README

---

## [v0.1.0] - 2026-10-29

- `hob`, or `hb` for short, in PowerShell, cmd and Git Bash
- `hb to <place>` jumps, ranked by how often and recently you go there
- Picker for ambiguous or unmatched jumps
- `hb back` undoes the last move
- Plugins add commands that can move your shell, without ever eval-ing anything
- Git Bash is lookup-only: `cd "$(hob path git)"` (bash would rather do it itself)
- Installs as one folder on PATH; shell profiles left untouched
- `hob update` fetches the latest release
- Install script refuses an installer that doesn't match `SHA256SUMS.txt`
