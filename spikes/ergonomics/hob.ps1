# Ergonomics spike loader. Dot-source it into a session:  . .\spikes\ergonomics\hob.ps1
# Dot-sourcing matters: the prefix alias and shortcuts have to land in the caller's global scope.
param(
    [string]$Alias = 'h',
    [switch]$NoShortcuts
)

Import-Module (Join-Path $PSScriptRoot 'hob.psm1') -Force -Global
$global:HobSpikeShortcuts = @()

if ($Alias) {
    $existing = Get-Alias -Name $Alias -ErrorAction SilentlyContinue
    if ($existing -and $existing.Definition -ne 'hob') {
        Write-Host "hob: '$Alias' now runs hob in this session (it was an alias for $($existing.Definition))" -ForegroundColor DarkGray
    }
    if ($existing) { Remove-Item -LiteralPath "Alias:\$Alias" -Force }
    Set-Alias -Name $Alias -Value hob -Scope Global
}

if (-not $NoShortcuts) {
    foreach ($name in (hob __shortcuts)) {
        $current = Get-Command -Name $name -ErrorAction SilentlyContinue
        if ($current -and -not ($current.CommandType -eq 'Function' -and $current.Definition -match '^\s*hob \$plugin')) {
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
if ($global:HobSpikeShortcuts) { $loaded += " | shortcuts: $($global:HobSpikeShortcuts -join ', ')" }
Write-Host $loaded -ForegroundColor DarkGray
