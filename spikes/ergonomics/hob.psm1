# In-process core for the ergonomics spike. Jumps resolve inside the shell because starting any process
# costs ~70 ms on this EDR-scanned machine. Only plugin commands start a process, and since a child
# cannot change its parent's directory, they move the shell through the directives file instead.

$script:SpikeDir = $PSScriptRoot
$script:PluginsDir = Join-Path $PSScriptRoot 'plugins'
$script:LocalRootsFile = Join-Path $PSScriptRoot 'roots.local.json'
$script:Builtins = [ordered]@{
    list  = 'Show everything hob knows'
    back  = 'Go back to where the last jump came from'
    naive = 'Try to cd from inside a child process, to watch it fail'
}
$script:Model = $null
$script:ModelStamp = $null

function Write-HobError {
    param([string]$Message)
    [Console]::Error.WriteLine("hob: $Message")
    $global:LASTEXITCODE = 1
}

function Get-HobRoots {
    # LOCALAPPDATA\Temp rather than $env:TEMP, which can be an 8.3 short path.
    $temp = Join-Path $env:LOCALAPPDATA 'Temp'
    if (-not (Test-Path -LiteralPath $temp)) { $temp = [IO.Path]::GetTempPath() }
    $roots = @{
        home = $HOME
        temp = $temp
        hob  = [IO.Path]::GetFullPath((Join-Path $script:SpikeDir '..\..'))
        git  = Join-Path $HOME 'Documents\git'
    }
    if (Test-Path -LiteralPath $script:LocalRootsFile) {
        $local = Get-Content -Raw -LiteralPath $script:LocalRootsFile | ConvertFrom-Json
        foreach ($p in $local.PSObject.Properties) { $roots[$p.Name] = [string]$p.Value }
    }
    $roots
}

function Expand-HobPath {
    param([string]$Template, [hashtable]$Roots, [string]$Base)
    $expanded = [regex]::Replace($Template, '\{(\w+)\}', {
            param($m)
            $name = $m.Groups[1].Value
            if (-not $Roots.ContainsKey($name)) { throw "unknown root {$name} in '$Template'" }
            $Roots[$name]
        })
    if ($Base) { $expanded = [IO.Path]::Combine($Base, $expanded) }
    [IO.Path]::GetFullPath($expanded)
}

function Get-HobModelStamp {
    $files = @(Get-ChildItem -LiteralPath $script:PluginsDir -Directory | ForEach-Object { Join-Path $_.FullName 'plugin.json' })
    $files += $script:LocalRootsFile
    ($files | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { "$_|$((Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks)" }) -join ';'
}

# Manifests are re-read only when one changes, so edits are live without paying the parse on every call.
function Get-HobModel {
    $stamp = Get-HobModelStamp
    if ($script:Model -and $stamp -eq $script:ModelStamp) { return $script:Model }

    $roots = Get-HobRoots
    $plugins = @()
    foreach ($dir in Get-ChildItem -LiteralPath $script:PluginsDir -Directory) {
        $manifestPath = Join-Path $dir.FullName 'plugin.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
        try {
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -ErrorAction Stop
            $root = $null
            if ($manifest.root) { $root = Expand-HobPath $manifest.root $roots }
            $plugin = [pscustomobject]@{
                Kind = 'plugin'; Name = $manifest.name; Description = $manifest.description
                Flat = [bool]$manifest.flat; Dir = $dir.FullName; Root = $root; Children = @()
            }
            $children = @()
            if ($manifest.locations) {
                foreach ($p in $manifest.locations.PSObject.Properties) {
                    $path = Expand-HobPath $p.Value $roots $root
                    $children += [pscustomobject]@{ Kind = 'location'; Name = $p.Name; Description = $path; Path = $path; Plugin = $plugin }
                }
            }
            if ($manifest.commands) {
                foreach ($p in $manifest.commands.PSObject.Properties) {
                    $run = @($p.Value.run | ForEach-Object { $_.Replace('{plugin}', $dir.FullName) })
                    $children += [pscustomobject]@{ Kind = 'command'; Name = $p.Name; Description = $p.Value.description; Run = $run; Plugin = $plugin }
                }
            }
            $plugin.Children = $children
            $plugins += $plugin
        }
        catch { Write-Warning "hob: skipped $manifestPath ($_)" }
    }

    $top = @(foreach ($name in $script:Builtins.Keys) { [pscustomobject]@{ Kind = 'builtin'; Name = $name; Description = $script:Builtins[$name] } })
    foreach ($plugin in $plugins) {
        if ($plugin.Flat) { $top += $plugin.Children } else { $top += $plugin }
    }

    $script:Model = [pscustomobject]@{ Plugins = $plugins; Top = $top }
    $script:ModelStamp = $stamp
    $script:Model
}

# Exact match wins; otherwise a unique prefix is accepted so `h sp d` works without completion.
function Find-HobEntry {
    param($Entries, [string]$Token)
    $exact = @($Entries | Where-Object { $_.Name -eq $Token })
    if ($exact.Count) { return @{ Entry = $exact[0]; Candidates = $exact } }
    $candidates = @($Entries | Where-Object { $_.Name -like "$([WildcardPattern]::Escape($Token))*" })
    $entry = $null
    if ($candidates.Count -eq 1) { $entry = $candidates[0] }
    @{ Entry = $entry; Candidates = $candidates }
}

function Resolve-HobWords {
    param($Top, [string[]]$Words)
    $entries = $Top
    $scope = 'hob'
    $i = 0
    do {
        $found = Find-HobEntry $entries $Words[$i]
        if (-not $found.Entry) {
            if ($found.Candidates.Count -gt 1) { Write-HobError "'$($Words[$i])' is ambiguous in ${scope}: $(($found.Candidates | ForEach-Object Name) -join ', ')" }
            else { Write-HobError "'$($Words[$i])' is not something $scope knows. Try 'hob list'." }
            return $null
        }
        $entry = $found.Entry
        $i++
        if ($entry.Kind -eq 'plugin') { $entries = $entry.Children; $scope = $entry.Name }
    } while ($entry.Kind -eq 'plugin' -and $i -lt $Words.Count)
    @{ Entry = $entry; Rest = @($Words | Select-Object -Skip $i) }
}

function Get-HobTargetDirectory {
    param($Entry)
    if ($Entry.Kind -eq 'location') { return $Entry.Path }
    if ($Entry.Kind -eq 'plugin') { return $Entry.Root }
    $null
}

function Invoke-HobJump {
    param($Entry)
    $dir = Get-HobTargetDirectory $Entry
    if (-not $dir) { Show-HobPlugin $Entry; return }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-HobError "'$($Entry.Name)' points at $dir, which does not exist"; return }
    Push-Location -LiteralPath $dir -StackName hob
}

function Invoke-HobDirective {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $directive = $line | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Warning "hob: ignored malformed directive: $line"; continue }
        if ($directive -isnot [System.Management.Automation.PSCustomObject]) {
            Write-Warning "hob: ignored directive that is not an object: $line"; continue
        }

        foreach ($prop in $directive.PSObject.Properties) {
            switch ($prop.Name) {
                'cd' {
                    if ($prop.Value -is [string] -and (Test-Path -LiteralPath $prop.Value -PathType Container)) {
                        Push-Location -LiteralPath $prop.Value -StackName hob
                    }
                    else { Write-Warning "hob: ignored cd to a missing or invalid path: $($prop.Value)" }
                }
                'env' {
                    if ($prop.Value -isnot [System.Management.Automation.PSCustomObject]) {
                        Write-Warning 'hob: ignored env directive that is not an object'; continue
                    }
                    foreach ($var in $prop.Value.PSObject.Properties) {
                        if ($var.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                            Write-Warning "hob: ignored invalid environment variable name: $($var.Name)"; continue
                        }
                        if ($null -eq $var.Value) { Remove-Item -LiteralPath "Env:\$($var.Name)" -ErrorAction SilentlyContinue }
                        else { Set-Item -LiteralPath "Env:\$($var.Name)" -Value ([string]$var.Value) }
                    }
                }
                'back' {
                    try { Pop-Location -StackName hob -ErrorAction Stop }
                    catch { Write-Warning 'hob: nothing to go back to' }
                }
                default { Write-Warning "hob: ignored unknown directive '$($prop.Name)'" }
            }
        }
    }
}

function Invoke-HobCommand {
    param($Command, [string[]]$Extra)
    $file = [IO.Path]::GetTempFileName()
    $env:HOB_DIRECTIVES = $file
    $env:HOB_PLUGIN_DIR = $Command.Plugin.Dir
    $code = 0
    try {
        $exe = $Command.Run[0]
        $runArgs = @($Command.Run | Select-Object -Skip 1) + @($Extra)
        & $exe @runArgs
        $code = $LASTEXITCODE
        Invoke-HobDirective -Lines (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue)
    }
    finally {
        Remove-Item -LiteralPath Env:\HOB_DIRECTIVES, Env:\HOB_PLUGIN_DIR -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
    $global:LASTEXITCODE = $code
}

function Invoke-HobNaive {
    param($Model, [string[]]$Words)
    if (-not $Words.Count) { Write-HobError 'usage: hob naive <location>'; return }
    $resolved = Resolve-HobWords $Model.Top $Words
    if (-not $resolved) { return }
    $dir = Get-HobTargetDirectory $resolved.Entry
    if (-not $dir) { Write-HobError "'$($resolved.Entry.Name)' is not a location"; return }
    Write-Output 'A child cmd.exe changes its own directory and prints where it ended up:'
    & cmd.exe /d /c cd /d $dir '&&' cd
    Write-Output "It has exited. You are still in $((Get-Location).Path), because a child cannot move its parent."
}

function Format-HobRow {
    param([string]$Name, [string]$Detail, [int]$Indent)
    (' ' * $Indent) + $Name.PadRight(14 - $Indent) + $Detail
}

function Show-HobPlugin {
    param($Plugin)
    Format-HobRow $Plugin.Name $Plugin.Description 0
    if ($Plugin.Root) { Format-HobRow '(itself)' $Plugin.Root 2 }
    foreach ($child in $Plugin.Children) { Format-HobRow $child.Name $child.Description 2 }
}

function Show-HobList {
    param($Model)
    foreach ($plugin in @($Model.Plugins | Where-Object Flat)) {
        "$($plugin.Description) (from '$($plugin.Name)', used straight off hob)"
        foreach ($child in $plugin.Children) { Format-HobRow $child.Name $child.Description 2 }
        ''
    }
    foreach ($plugin in @($Model.Plugins | Where-Object { -not $_.Flat })) {
        Show-HobPlugin $plugin
        ''
    }
    'Built-ins'
    foreach ($name in $script:Builtins.Keys) { Format-HobRow $name $script:Builtins[$name] 2 }
}

# Same value<TAB>description protocol the real core will expose, so adapters stay thin.
function Get-HobCompletion {
    param($Model, [string]$Partial, [string[]]$Words)
    $entries = $Model.Top
    foreach ($word in $Words) {
        $entry = (Find-HobEntry $entries $word).Entry
        if ($entry -and $entry.Kind -eq 'plugin') { $entries = $entry.Children }
        elseif ($entry -and $entry.Kind -eq 'builtin' -and $entry.Name -eq 'naive') { $entries = @($Model.Top | Where-Object Kind -ne 'builtin') }
        else { return }
    }
    foreach ($entry in @($entries | Where-Object { $_.Name -like "$([WildcardPattern]::Escape($Partial))*" })) {
        "$($entry.Name)`t$($entry.Description)"
    }
}

function hob {
    $words = @($args | ForEach-Object { [string]$_ })
    $global:LASTEXITCODE = 0
    $model = Get-HobModel

    if ($words.Count -eq 0) { Show-HobList $model; return }
    if ($words[0] -eq '__complete') {
        $partial = ''
        if ($words.Count -gt 1) { $partial = $words[1] }
        Get-HobCompletion $model $partial @($words | Select-Object -Skip 2)
        return
    }
    if ($words[0] -eq '__shortcuts') { $model.Plugins | Where-Object { -not $_.Flat } | ForEach-Object Name; return }

    $resolved = Resolve-HobWords $model.Top $words
    if (-not $resolved) { return }
    $entry = $resolved.Entry
    switch ($entry.Kind) {
        'builtin' {
            if ($entry.Name -eq 'list') { Show-HobList $model }
            elseif ($entry.Name -eq 'back') {
                try { Pop-Location -StackName hob -ErrorAction Stop }
                catch { Write-HobError 'nothing to go back to' }
            }
            else { Invoke-HobNaive $model $resolved.Rest }
        }
        'command' { Invoke-HobCommand $entry $resolved.Rest }
        default { Invoke-HobJump $entry }
    }
}

Export-ModuleMember -Function hob
