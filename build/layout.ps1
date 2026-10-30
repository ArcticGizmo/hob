# Copies the shell wrappers next to a published hob-cli.exe. Shared by pack.ps1 and dev.ps1 so a checkout runs
# with exactly the layout an install has: the wrappers find the exe, and each other, by relative path.
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'

$shell = Join-Path (Split-Path -Parent $PSScriptRoot) 'shell'
foreach ($file in 'hob.psm1', 'cmd\hob.cmd', 'bash\hob.sh', 'templates\shim.ps1', 'templates\shim.cmd', 'templates\shim.sh') {
    $target = Join-Path $Destination $file
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target))
    Copy-Item -LiteralPath (Join-Path $shell $file) -Destination $target
}
