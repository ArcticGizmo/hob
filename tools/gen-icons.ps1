# Regenerates src\Hob.Cli\hob.ico from hob.svg. Run after editing the SVG, then commit the .ico.
$ErrorActionPreference = 'Stop'
dotnet run --project (Join-Path $PSScriptRoot 'IconGen') -c Release
if ($LASTEXITCODE) { throw 'IconGen failed' }
