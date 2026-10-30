# PowerShell wrapper, loaded by the generated hob.ps1 on PATH, which PowerShell runs inside the calling session.
# hob-cli.exe owns everything hob knows. This answers what it can from the index the exe writes, because starting
# any process costs 50-100 ms on an EDR-scanned machine and a jump should not. Everything else, including every
# error, goes to the exe, which moves the shell by appending lines to the directives file.

$script:Exe = Join-Path $PSScriptRoot 'hob-cli.exe'
$script:Index = $null
$script:IndexStamp = $null
$script:IndexFormat = '# hob index 2 '
$script:EnvNamePattern = '^[A-Za-z_][A-Za-z0-9_]*$'
# Refused in every shell for consistency: bash runs or re-reads these, which would turn a value into code.
$script:EnvDenyPattern = '^(PROMPT_COMMAND|PS[0-4]|ENV|BASH_ENV|BASH_FUNC_.*|BASHOPTS|SHELLOPTS|IFS)$'

function Write-HobError {
    param([string]$Message)
    [Console]::Error.WriteLine("hob: $Message")
    $global:LASTEXITCODE = 1
}

function Get-HobDataDir {
    if ($env:HOB_HOME) { return [IO.Path]::GetFullPath($env:HOB_HOME) }
    Join-Path $env:USERPROFILE '.hob'
}

function Read-HobIndex {
    param([string]$File)
    $index = @{
        Current = $false; To = @{}; Go = @{}; Run = @{}; Sub = @{}
        Top = New-Object System.Collections.Generic.List[object]
        ToComp = New-Object System.Collections.Generic.List[object]
        Watch = New-Object System.Collections.Generic.List[string]
    }
    $first = $true
    foreach ($line in [IO.File]::ReadLines($File)) {
        if ($first) { $index.Current = $line.StartsWith($script:IndexFormat); $first = $false; continue }
        $f = $line.Split('|')
        switch ($f[0]) {
            'to' { $index.To[$f[1]] = $f[2] }
            'go' { $index.Go[$f[1]] = $f[2] }
            'run' { $index.Run[$f[1]] = @($f[2], $f[3]) }
            'top' { $index.Top.Add(@($f[1], $f[2])) }
            'sub' {
                if (-not $index.Sub.ContainsKey($f[1])) { $index.Sub[$f[1]] = New-Object System.Collections.Generic.List[object] }
                $index.Sub[$f[1]].Add(@($f[2], $f[3], $f[4]))
            }
            'tocomp' { $index.ToComp.Add(@($f[1], $f[2])) }
            'watch' { $index.Watch.Add($f[1]) }
        }
    }
    $index
}

# Re-read only when the file changes. Stale when anything it lists as a source is newer, which is the same rule
# the exe and bash apply; .NET calls rather than cmdlets because this runs on every command and PowerShell 7's
# file cmdlets made it several times slower.
function Get-HobIndex {
    $file = Join-Path (Get-HobDataDir) 'index.txt'
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $info = New-Object IO.FileInfo $file
        if ($info.Exists) {
            $stamp = "$file|$($info.Length)|$($info.LastWriteTimeUtc.Ticks)"
            if ($stamp -ne $script:IndexStamp) {
                $script:Index = Read-HobIndex $file
                $script:IndexStamp = $stamp
            }
            $built = $info.LastWriteTimeUtc
            $stale = -not $script:Index.Current
            foreach ($path in $script:Index.Watch) {
                if ($stale) { break }
                $stale = [IO.File]::GetLastWriteTimeUtc($path) -gt $built -or ([IO.Directory]::Exists($path) -and [IO.Directory]::GetLastWriteTimeUtc($path) -gt $built)
            }
            if (-not $stale) { return $script:Index }
        }
        if ($attempt -eq 0) { & $script:Exe index }
    }
    $null
}

function Add-HobVisit {
    param([string]$Path, [string]$How)
    if ($env:HOB_NO_HISTORY) { return }
    try { [IO.File]::AppendAllText((Join-Path (Get-HobDataDir) 'history.tsv'), "$([DateTime]::UtcNow.Ticks)`t$How`t$Path`t-1`t`n") }
    catch { }
}

# One action per line, "verb value", because cmd and bash can split that with builtins but cannot parse JSON.
# Only these four verbs are applied, and nothing is evaluated as code.
function Invoke-HobDirective {
    param([string[]]$Lines)

    foreach ($raw in $Lines) {
        $line = $raw.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $verb, $value = $line -split ' ', 2
        switch -CaseSensitive ($verb) {
            'cd' {
                if ($value -and [IO.Path]::IsPathRooted($value) -and (Test-Path -LiteralPath $value -PathType Container)) { Push-Location -LiteralPath $value -StackName hob }
                else { Write-Warning "hob: ignored cd to a missing or invalid path: $value" }
            }
            'back' {
                if ($null -ne $value) { Write-Warning "hob: ignored malformed directive: $line" }
                else {
                    try { Pop-Location -StackName hob -ErrorAction Stop }
                    catch { Write-HobError 'nothing to go back to' }
                }
            }
            'env' {
                $name, $val = "$value" -split '=', 2
                if ($null -eq $val -or $name -notmatch $script:EnvNamePattern -or $name -match $script:EnvDenyPattern) { Write-Warning "hob: ignored invalid env directive: $line" }
                else { Set-Item -LiteralPath "Env:\$name" -Value $val }
            }
            'unset' {
                if ("$value" -notmatch $script:EnvNamePattern -or "$value" -match $script:EnvDenyPattern) { Write-Warning "hob: ignored invalid unset directive: $line" }
                else { Remove-Item -LiteralPath "Env:\$value" -ErrorAction SilentlyContinue }
            }
            default { Write-Warning "hob: ignored unknown directive: $line" }
        }
    }
}

# Runs a program with a fresh directives file, then applies what it asked for. The body's output flows
# through, so `code (hob path)` still gets a picked folder; the body sets $global:LASTEXITCODE.
function Invoke-HobWithDirectives {
    param([scriptblock]$Body, [string]$PluginDir)
    $file = [IO.Path]::GetTempFileName()
    $env:HOB_DIRECTIVES = $file
    $env:HOB_SHELL = 'powershell'
    if ($PluginDir) { $env:HOB_PLUGIN_DIR = $PluginDir }
    try {
        & $Body
        $code = $global:LASTEXITCODE
        Invoke-HobDirective -Lines ([IO.File]::ReadAllLines($file))
        if (-not $global:LASTEXITCODE) { $global:LASTEXITCODE = $code }
    }
    finally {
        Remove-Item -LiteralPath Env:\HOB_DIRECTIVES, Env:\HOB_SHELL, Env:\HOB_PLUGIN_DIR -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
}

function Invoke-HobCommand {
    param([string]$Exe, [string]$PluginDir, [string[]]$Extra)
    Invoke-HobWithDirectives -PluginDir $PluginDir -Body {
        if ($Exe -like '*.ps1') {
            # Plugins are trusted, so PowerShell commands run in this session (~5 ms rather than 200 ms+ for a
            # new process) and may move it directly. A move is re-recorded on hob's stack so `hob back` undoes it.
            $before = Get-Location
            $global:LASTEXITCODE = 0
            & $Exe @Extra
            if (-not $?) { $global:LASTEXITCODE = 1 }
            $after = Get-Location
            if ($after.Path -ne $before.Path) {
                Set-Location -LiteralPath $before.Path
                Push-Location -LiteralPath $after.Path -StackName hob
            }
        }
        else { & $Exe @Extra }
    }
}

function Invoke-HobExe {
    param([string[]]$Words)
    if (-not [IO.File]::Exists($script:Exe)) { Write-HobError "missing $($script:Exe); reinstall hob"; return }
    Invoke-HobWithDirectives -Body { & $script:Exe hob @Words }
}

function Invoke-HobJump {
    param([string]$Path, [string]$How)
    Push-Location -LiteralPath $Path -StackName hob
    Add-HobVisit $Path $How
}

# Mirrors the exe's matching for the first word only: exact name, else a unique prefix.
function Find-HobTop {
    param($Index, [string]$Word)
    $names = @($Index.Top | ForEach-Object { $_[0] })
    if ($names -contains $Word) { return @($names | Where-Object { $_ -eq $Word })[0] }
    $hits = @($names | Where-Object { $_.StartsWith($Word, [StringComparison]::OrdinalIgnoreCase) })
    if ($hits.Count -eq 1) { return $hits[0] }
    $null
}

function Get-HobCompletion {
    param($Index, [string]$Partial, [string[]]$Words)
    $ignoreCase = [StringComparison]::OrdinalIgnoreCase
    # A word starting with '-' never gets here: PowerShell completes it as one of the script's own parameters.
    if ($Words.Count -eq 0) {
        foreach ($top in $Index.Top) { if ($top[0].StartsWith($Partial, $ignoreCase)) { "$($top[0])`t$($top[1])" } }
        return
    }
    $first = Find-HobTop $Index $Words[0]
    if ($first -in 'to', 'cd', 'path') {
        if ($Words.Count -eq 1) {
            foreach ($place in $Index.ToComp) {
                $name = @($place[0].Split(' '))[-1]
                if ($name.StartsWith($Partial, $ignoreCase) -or $place[0].StartsWith($Partial, $ignoreCase)) { "$($place[0])`t$($place[1])" }
            }
        }
        elseif ($Words.Count -eq 2 -and $Words[1] -notlike '-*') {
            $plugin = Find-HobTop $Index $Words[1]
            if ($plugin -and $Index.Sub.ContainsKey($plugin)) {
                foreach ($child in $Index.Sub[$plugin]) {
                    if ($child[1] -eq 'place' -and $child[0].StartsWith($Partial, $ignoreCase)) { "$($child[0])`t$($child[2])" }
                }
            }
        }
        return
    }
    if ($Words.Count -eq 1 -and $first -and $Index.Sub.ContainsKey($first)) {
        foreach ($child in $Index.Sub[$first]) { if ($child[0].StartsWith($Partial, $ignoreCase)) { "$($child[0])`t$($child[2])" } }
    }
}

function Get-HobShimCompletion {
    param($CommandAst, [string]$WordToComplete, [string]$Prefix)
    $index = Get-HobIndex
    if (-not $index) { return }
    $words = @()
    if ($Prefix) { $words += $Prefix }
    foreach ($element in @($CommandAst.CommandElements | Select-Object -Skip 1)) {
        if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $words += $element.Value }
        else { $words += $element.Extent.Text }
    }
    if ($WordToComplete -and $words.Count) { $words = @($words | Select-Object -First ($words.Count - 1)) }
    foreach ($line in Get-HobCompletion $index $WordToComplete $words) {
        $value, $description = $line -split "`t", 2
        if (-not $description) { $description = $value }
        [System.Management.Automation.CompletionResult]::new($value, $value, 'ParameterValue', $description)
    }
}

function hob {
    # Splatting an empty argument list from the PATH script passes a single $null, so empty words are dropped.
    $words = @($args | Where-Object { "$_" -ne '' } | ForEach-Object { [string]$_ })
    $global:LASTEXITCODE = 0
    $index = Get-HobIndex

    if ($index -and $words.Count) {
        $verb = $words[0].ToLowerInvariant()
        $rest = @($words | Select-Object -Skip 1)
        if ($verb -eq 'back' -and $rest.Count -eq 0) {
            try { Pop-Location -StackName hob -ErrorAction Stop }
            catch { Write-HobError 'nothing to go back to' }
            return
        }
        if ($verb -in 'to', 'cd', 'path') {
            if ($rest.Count -and -not $rest[0].StartsWith('-')) {
                $path = $index.To[($rest -join ' ')]
                if ($path -and [IO.Directory]::Exists($path)) {
                    if ($verb -eq 'path') { $path; Add-HobVisit $path 'path' }
                    else { Invoke-HobJump $path 'to' }
                    return
                }
            }
        }
        else {
            $key = (@($words | Select-Object -First 2) -join ' ')
            $path = $index.Go[$key]
            if ($words.Count -le 2 -and $path -and [IO.Directory]::Exists($path)) { Invoke-HobJump $path 'direct'; return }
            $run = $index.Run[$key]
            if ($words.Count -ge 2 -and $run) { Invoke-HobCommand $run[0] $run[1] @($words | Select-Object -Skip 2); return }
        }
    }
    Invoke-HobExe $words
}

# Nothing is exported: a global `hob` function would take precedence over hob.ps1 on PATH, and with it the
# completer declared there. The generated scripts call in through the module object instead.
Export-ModuleMember -Function @()
