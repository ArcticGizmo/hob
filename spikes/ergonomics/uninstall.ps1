# Reverses install.ps1: removes the command folder from your user PATH and deletes the generated files.
# Your jump history is kept unless you pass -History.
param([switch]$History)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'hob.psm1') -Force
$module = Get-Module hob
$binDir = & $module { $script:BinDir }
$generated = @(& $module { $script:BinDir; $script:IndexFile; $script:SettingsFile })
$historyFile = & $module { $script:HistoryFile }

if (& $module { param($e) Set-HobUserPathEntry $e -Remove } $binDir) { "Removed $binDir from your user PATH." }
else { "$binDir was not on your user PATH." }
$env:PATH = (@($env:PATH.Split(';') | Where-Object { $_.TrimEnd('\') -ne $binDir.TrimEnd('\') }) -join ';')

foreach ($path in $generated) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; "Deleted $path" }
}
if ($History) {
    if (Test-Path -LiteralPath $historyFile) { Remove-Item -LiteralPath $historyFile; "Deleted $historyFile" }
}
elseif (Test-Path -LiteralPath $historyFile) { "Kept your jump history in $historyFile (pass -History to delete it)." }
