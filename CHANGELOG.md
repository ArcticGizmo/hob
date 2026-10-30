# Changelog

All notable changes to hob are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---

## [v0.2.0] - 2026-10-30

- Your own places: `hob to --add <name> [folder]`, `hob to --rm <name>`
- `nav` plugin retired; its places are now starters you can delete (they stay deleted)
- Picker, `recent` and place management work in cmd and Git Bash
- Same error messages in every shell (there is only one copy now)
- `hob --version` / `-v` and `hob --help` / `-h`
- `hob` and `hb` alone no longer claim to be ambiguous
- `hob list` removed; `hob` was already saying everything
- `hob naive` retired with honours
- `to, cd` share one line, as befits one command
- PowerShell plugin commands run in cmd and Git Bash (no moving your shell there)
- `HOB_HOME` moves the whole data folder

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
