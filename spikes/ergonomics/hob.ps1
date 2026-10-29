# Ergonomics spike loader. Dot-source it into a session:  . .\spikes\ergonomics\hob.ps1
# Dot-sourcing matters: the prefix alias and shortcuts have to land in the caller's global scope.
param(
    [string]$Alias = 'h',
    [switch]$NoShortcuts,
    [switch]$FlatPlaces
)

Import-Module (Join-Path $PSScriptRoot 'hob.psm1') -Force -Global -ArgumentList $FlatPlaces.IsPresent
$global:HobSpikeShortcuts = @()

if ($Alias) {
    $existing = Get-Alias -Name $Alias -ErrorAction SilentlyContinue
    if ($existing -and $existing.Definition -ne 'hob') {
        Write-Host "hob: '$Alias' now runs hob in this session (it was an alias for $($existing.Definition))" -ForegroundColor DarkGray
    }
    if ($existing) { Remove-Item -LiteralPath "Alias:\$Alias" -Force }
    Set-Alias -Name $Alias -Value hob -Scope Global
}

# Get-Command is far too slow for this at shell start: over a second in PowerShell 7 even with -ListImported,
# and ~60 ms per name for a PATH search. Checking the function and alias drives, loaded modules and PATH
# directly covers what a shortcut could realistically hide in a few milliseconds.
$hobNameTaken = {
    param([string]$Name)
    $function = Get-Item -LiteralPath "Function:\$Name" -ErrorAction SilentlyContinue
    if ($function -and $function.Definition -notmatch '^\s*hob \$plugin') { return $true }
    if (Test-Path -LiteralPath "Alias:\$Name") { return $true }
    foreach ($module in Get-Module) { if ($module.ExportedCommands.ContainsKey($Name)) { return $true } }
    foreach ($dir in $env:PATH.Split(';')) {
        $dir = $dir.Trim('"')
        if (-not $dir) { continue }
        foreach ($ext in $env:PATHEXT.Split(';')) {
            try { if ([IO.File]::Exists([IO.Path]::Combine($dir, $Name + $ext))) { return $true } }
            catch { break }
        }
    }
    $false
}

if (-not $NoShortcuts) {
    foreach ($name in (hob __shortcuts)) {
        if (& $hobNameTaken $name) {
            Write-Warning "hob: skipped shortcut '$name' because it would hide an existing command"; continue
        }
        $plugin = $name
        Set-Item -LiteralPath "Function:\global:$name" -Value { hob $plugin @args }.GetNewClosure()
        $global:HobSpikeShortcuts += $name
    }
}

$hobCompleter = {
    param($wordToComplete, $commandAst, $cursorPosition)

    $elements = @($commandAst.CommandElements)
    $words = @()
    if ($global:HobSpikeShortcuts -contains $elements[0].Extent.Text) { $words += $elements[0].Extent.Text }
    foreach ($element in ($elements | Select-Object -Skip 1)) {
        if ($element.Extent.EndOffset -ge $cursorPosition) { break }
        if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $words += $element.Value }
        else { $words += $element.Extent.Text }
    }

    hob __complete $wordToComplete @words | ForEach-Object {
        $value, $description = $_ -split "`t", 2
        if (-not $description) { $description = $value }
        [System.Management.Automation.CompletionResult]::new($value, $value, 'ParameterValue', $description)
    }
}
$completerNames = @('hob') + $global:HobSpikeShortcuts
if ($Alias) { $completerNames += $Alias }
Register-ArgumentCompleter -Native -CommandName $completerNames -ScriptBlock $hobCompleter

$loaded = 'hob spike loaded'
if ($Alias) { $loaded += " | prefix alias: $Alias" }
if ($FlatPlaces) { $loaded += ' | flat places' }
if ($global:HobSpikeShortcuts) { $loaded += " | shortcuts: $($global:HobSpikeShortcuts -join ', ')" }
Write-Host $loaded -ForegroundColor DarkGray
