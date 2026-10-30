# Builds a Velopack release locally: hob-cli.exe plus the shell wrappers, packed into Setup.exe and an update
# feed under artifacts\releases. The layout is the one build\layout.ps1 describes.
param(
    [string]$Version = '0.0.1',
    # vpk refuses to pack a version that is not newer than one already in the feed; this starts the feed over.
    [switch]$Clean,
    # Native AOT starts faster, but needs the MSVC build tools, which GitHub's Windows runners have.
    [switch]$Aot
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$publish = Join-Path $root 'artifacts\publish'
$releases = Join-Path $root 'artifacts\releases'
if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
if ($Clean -and (Test-Path -LiteralPath $releases)) { Remove-Item -LiteralPath $releases -Recurse -Force }

# Single-file but not compressed: decompressing on every start cost ~170 ms, and Setup.exe compresses anyway.
$mode = if ($Aot) { @('-p:PublishAot=true') } else { @('-p:PublishSingleFile=true', '-p:PublishReadyToRun=true') }
dotnet publish (Join-Path $root 'src\Hob.Cli\Hob.Cli.csproj') -c Release -r win-x64 --self-contained true @mode `
    -p:DebugType=embedded -p:Version=$Version -o $publish -nologo -v q
if ($LASTEXITCODE) { throw 'dotnet publish failed' }
& (Join-Path $PSScriptRoot 'layout.ps1') -Destination $publish

Push-Location $root
try {
    dotnet tool restore | Out-Null
    dotnet vpk pack --packId Hob --packTitle hob --packVersion $Version --packDir $publish --mainExe hob-cli.exe `
        --icon (Join-Path $root 'src\Hob.Cli\hob.ico') --shortcuts None --outputDir $releases
    if ($LASTEXITCODE) { throw 'vpk pack failed' }
}
finally { Pop-Location }

Get-ChildItem -LiteralPath $releases | ForEach-Object { '{0,-36} {1,8:N1} MB' -f $_.Name, ($_.Length / 1MB) }
