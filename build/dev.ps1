# Builds a checkout into artifacts\dev with the same layout as an install. Run it again after any change, to
# the exe or the shell wrappers. -Setup then puts its commands on your user PATH, in place of an installed
# hob's; `artifacts\dev\hob-cli.exe setup --undo` reverses that.
param([switch]$Setup)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root 'artifacts\dev'

# Framework-dependent and untrimmed so it builds in seconds; the release is self-contained.
dotnet publish (Join-Path $root 'src\Hob.Cli\Hob.Cli.csproj') -c Release -r win-x64 --self-contained false `
    -p:PublishTrimmed=false -p:Version=0.0.0-dev -o $out -nologo -v q
if ($LASTEXITCODE) { throw 'dotnet publish failed' }
& (Join-Path $PSScriptRoot 'layout.ps1') -Destination $out

if ($Setup) { & (Join-Path $out 'hob-cli.exe') setup }
else { "Built $out. Add -Setup to put it on your PATH." }
