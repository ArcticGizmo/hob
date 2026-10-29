# Builds a Velopack release locally: hob-cli.exe plus the scripts it installs, packed into Setup.exe and an
# update feed under artifacts\releases. The package mirrors the spike folder's layout because hob.psm1, the
# cmd adapter and the bash library find each other by relative path.
param(
    [string]$Version = '0.0.1',
    # vpk refuses to pack a version that is not newer than one already in the feed; this starts the feed over.
    [switch]$Clean
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$spike = Join-Path $root 'spikes\ergonomics'
$publish = Join-Path $root 'artifacts\publish'
$releases = Join-Path $root 'artifacts\releases'
if (Test-Path -LiteralPath $publish) { Remove-Item -LiteralPath $publish -Recurse -Force }
if ($Clean -and (Test-Path -LiteralPath $releases)) { Remove-Item -LiteralPath $releases -Recurse -Force }

dotnet publish (Join-Path $root 'src\Hob.Cli\Hob.Cli.csproj') -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:DebugType=embedded `
    -p:Version=$Version -o $publish -nologo -v q
if ($LASTEXITCODE) { throw 'dotnet publish failed' }

$files = @('hob.psm1', 'cmd\hob.cmd', 'bash\hob.sh', 'templates\shim.ps1', 'templates\shim.cmd', 'templates\shim.sh')
foreach ($file in $files) {
    $target = Join-Path $publish $file
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target))
    Copy-Item -LiteralPath (Join-Path $spike $file) -Destination $target
}
# Only general-purpose plugins ship. The demo `spike` plugin points into this repository, so it only means
# something in a checkout; people's own plugins go in their data folder, which updates leave alone.
Copy-Item -LiteralPath (Join-Path $spike 'plugins\nav') -Destination (Join-Path $publish 'plugins\nav') -Recurse

Push-Location $root
try {
    dotnet tool restore | Out-Null
    dotnet vpk pack --packId Hob --packTitle hob --packVersion $Version --packDir $publish --mainExe hob-cli.exe `
        --shortcuts None --outputDir $releases
    if ($LASTEXITCODE) { throw 'vpk pack failed' }
}
finally { Pop-Location }

Get-ChildItem -LiteralPath $releases | ForEach-Object { '{0,-36} {1,8:N1} MB' -f $_.Name, ($_.Length / 1MB) }
