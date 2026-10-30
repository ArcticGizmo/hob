# PowerShell plugin commands run inside the caller's session, so this moves the shell directly.
$dir = Get-Item -LiteralPath (Get-Location).Path
while ($dir -and -not (Test-Path -LiteralPath (Join-Path $dir.FullName '.git'))) { $dir = $dir.Parent }
if (-not $dir) {
    Write-Warning 'not inside a git repository'
    $global:LASTEXITCODE = 1
    return
}
Set-Location -LiteralPath $dir.FullName
