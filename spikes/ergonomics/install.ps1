# One-time install for the ergonomics spike. Writes the command folder and adds it to your user PATH, which
# is the only change outside hob's own folders. Shell startup files ($PROFILE, .bashrc, cmd AutoRun) are never
# touched, and nothing has to run in each new terminal.
param(
    [string]$Alias = 'hb',
    [switch]$NoShortcuts,
    # Write the commands but leave PATH alone, e.g. to add the folder yourself.
    [switch]$KeepPath
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'hob.psm1') -Force
$module = Get-Module hob
$settingsFile = & $module { $script:SettingsFile }
$binDir = & $module { $script:BinDir }

$folder = Split-Path -Parent $settingsFile
if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder) }
# Merged rather than overwritten, so plugin folders and roots you have set survive a reinstall.
$settings = [pscustomobject]@{}
if (Test-Path -LiteralPath $settingsFile) { $settings = Get-Content -Raw -LiteralPath $settingsFile | ConvertFrom-Json }
$settings | Add-Member -NotePropertyName alias -NotePropertyValue $Alias -Force
$settings | Add-Member -NotePropertyName shortcuts -NotePropertyValue (-not $NoShortcuts) -Force
[IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json -Depth 5))
& $module { Update-HobFiles }

$commands = @(Get-ChildItem -LiteralPath $binDir -Filter *.ps1 | ForEach-Object BaseName)
"Commands in ${binDir}: $($commands -join ', ')"

if ($KeepPath) {
    "PATH left alone. Add $binDir to it yourself to use them."
    return
}
if (& $module { param($e) Set-HobUserPathEntry $e } $binDir) { "Added $binDir to your user PATH." }
else { "$binDir is already on your user PATH." }
if (@($env:PATH.Split(';') | Where-Object { $_.TrimEnd('\') -eq $binDir.TrimEnd('\') }).Count -eq 0) { $env:PATH = "$binDir;$env:PATH" }
'Works in this window now and in every new terminal. Windows Terminal hands new tabs the environment it started with, so restart it once if a new tab cannot find hob.'
