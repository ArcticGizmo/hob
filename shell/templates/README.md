# Command templates

One file per shell for every command hob puts on PATH. `hob-cli.exe` renders them (`Shims.cs`) into `%USERPROFILE%\.hob\bin` during install, update and `setup`, and whenever plugins or settings change. Placeholders:

| Placeholder | Becomes |
|---|---|
| `{{PSM1}}` | Full path to `hob.psm1`, with `'` doubled for a PowerShell single-quoted string |
| `{{CMD}}` | Full path to `cmd\hob.cmd` |
| `{{SH}}` | Git Bash path to `bash/hob.sh` (`/c/...`), with `'` escaped for a bash single-quoted string |
| `{{PREFIX}}` | Words inserted before the user's arguments: empty for `hob` and the short name, the plugin name for a shortcut |

The renderer writes `shim.ps1` as UTF-8 with a BOM (Windows PowerShell 5.1 reads BOM-less files as the ANSI code page), `shim.cmd` with CRLF line endings (cmd misplaces `goto` and `call :label` targets otherwise) and `shim.sh` with LF.
