# In-process core for the ergonomics spike. Jumps resolve inside the shell because starting any process
# costs ~70 ms on this EDR-scanned machine. Only plugin commands start a process, and since a child
# cannot change its parent's directory, they move the shell through the directives file instead.
param([bool]$FlatPlaces = $false)

$script:SpikeDir = $PSScriptRoot
$script:PluginsDir = Join-Path $PSScriptRoot 'plugins'
$script:LocalRootsFile = Join-Path $PSScriptRoot 'roots.local.json'
$script:FlatPlaces = $FlatPlaces
$script:Builtins = [ordered]@{
    list  = 'Show everything hob knows'
    to    = 'Jump to a place: h to <place> or h to <plugin> <place>'
    cd    = 'Same as to'
    back   = 'Go back to where the last jump came from'
    recent = 'Places ranked by how often and how recently you go there'
    naive  = 'Try to cd from inside a child process, to watch it fail'
}
$script:PlaceBuiltins = @('to', 'cd', 'naive')
$script:ReadKey = { [Console]::ReadKey($true) }
# Machine-local and outside the repo: it records where you go, which is nobody else's business.
$script:HistoryFile = $env:HOB_SPIKE_HISTORY
if (-not $script:HistoryFile) { $script:HistoryFile = Join-Path $env:LOCALAPPDATA 'hob-spike\history.tsv' }
$script:History = @{}
$script:HistoryStamp = $null
$script:HistoryWarned = $false
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
                Dir = $dir.FullName; Root = $root; Children = @()
            }
            $children = @()
            if ($manifest.locations) {
                foreach ($p in $manifest.locations.PSObject.Properties) {
                    $path = Expand-HobPath $p.Value $roots $root
                    $children += [pscustomobject]@{
                        Kind = 'location'; Name = $p.Name; Qualified = "$($manifest.name) $($p.Name)"
                        Description = $path; Path = $path; Plugin = $plugin; Completion = $null
                    }
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
    $top += $plugins

    # Every place from every plugin, so `h to` can search them all. A plugin's root is a place named after it.
    $places = @()
    foreach ($plugin in $plugins) {
        if ($plugin.Root) {
            $places += [pscustomobject]@{
                Kind = 'location'; Name = $plugin.Name; Qualified = $plugin.Name
                Description = $plugin.Root; Path = $plugin.Root; Plugin = $plugin; Completion = $null
            }
        }
        $places += @($plugin.Children | Where-Object Kind -eq 'location')
    }
    # Short names complete as-is; a name shared by several plugins completes to its qualified form instead.
    foreach ($place in $places) {
        $shared = @($places | Where-Object Name -eq $place.Name).Count -gt 1
        $place.Completion = if ($shared) { $place.Qualified } else { $place.Name }
    }

    if ($script:FlatPlaces) {
        $topNames = @($top | ForEach-Object Name)
        $warned = @{}
        foreach ($place in $places) {
            if ($place.Completion -ne $place.Name) {
                if (-not $warned[$place.Name]) { Write-Warning "hob: '$($place.Name)' is not flat because several plugins have a place by that name" }
                $warned[$place.Name] = $true
                continue
            }
            if ($topNames -contains $place.Name) {
                if ($place.Name -ne $place.Plugin.Name) { Write-Warning "hob: '$($place.Name)' is not flat because it clashes with a built-in or plugin" }
                continue
            }
            $top += $place
        }
    }

    $script:Model = [pscustomobject]@{ Plugins = $plugins; Top = $top; Places = $places }
    $script:ModelStamp = $stamp
    $script:Model
}

# Exact match wins; otherwise a unique prefix is accepted so `h sp d` works without completion.
function Find-HobEntry {
    param($Entries, [string]$Token)
    $exact = @($Entries | Where-Object { $_.Name -eq $Token })
    if ($exact.Count -eq 1) { return @{ Entry = $exact[0]; Candidates = $exact } }
    if ($exact.Count -gt 1) { return @{ Entry = $null; Candidates = $exact } }
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
            elseif ($scope -eq 'hob' -and ($places = @($script:Model.Places | Where-Object Name -eq $Words[$i])).Count) {
                $suggestions = ($places | ForEach-Object { "'h to $($_.Qualified)'" }) -join ' or '
                if ($places.Count -eq 1) { $suggestions = "'h to $($Words[$i])'" }
                Write-HobError "'$($Words[$i])' is a place. Did you mean ${suggestions}?"
            }
            else { Write-HobError "'$($Words[$i])' is not something $scope knows. Try 'hob list'." }
            return $null
        }
        $entry = $found.Entry
        $i++
        if ($entry.Kind -eq 'plugin') { $entries = $entry.Children; $scope = $entry.Name }
    } while ($entry.Kind -eq 'plugin' -and $i -lt $Words.Count)
    @{ Entry = $entry; Rest = @($Words | Select-Object -Skip $i) }
}

function Resolve-HobPlace {
    param($Model, [string[]]$Words, [switch]$Quiet)
    if ($Words.Count -gt 2) {
        if (-not $Quiet) { Write-HobError "too many words for a place: '$($Words -join ' ')'" }
        return $null
    }

    $entries = $Model.Places
    $token = $Words[0]
    if ($Words.Count -eq 2) {
        $plugin = (Find-HobEntry $Model.Plugins $Words[0]).Entry
        if (-not $plugin) {
            if (-not $Quiet) { Write-HobError "'$($Words[0])' is not a plugin, so '$($Words -join ' ')' is not a place" }
            return $null
        }
        $entries = @($plugin.Children | Where-Object Kind -eq 'location')
        $token = $Words[1]
    }

    $found = Find-HobEntry $entries $token
    if ($found.Entry) { return $found.Entry }
    if ($Quiet) { return $null }
    if ($found.Candidates.Count -gt 1) {
        $names = ($found.Candidates | ForEach-Object Qualified) -join ', '
        Write-HobError "'$token' could be: $names. Be more specific, for example 'h to $($found.Candidates[0].Qualified)'."
    }
    else { Write-HobError "no place called '$($Words -join ' ')'. 'h to' lists them all." }
    $null
}

function Get-HobTargetDirectory {
    param($Entry)
    if ($Entry.Kind -eq 'location') { return $Entry.Path }
    if ($Entry.Kind -eq 'plugin') { return $Entry.Root }
    $null
}

function Invoke-HobJump {
    param($Entry, [string]$How = 'direct', [int]$PickIndex = -1, [string]$Query = '')
    $dir = Get-HobTargetDirectory $Entry
    if (-not $dir) { Show-HobPlugin $Entry; return }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-HobError "'$($Entry.Name)' points at $dir, which does not exist"; return }
    Push-Location -LiteralPath $dir -StackName hob
    Add-HobVisit $dir $How $PickIndex $Query
}

function Get-HobHistoryStamp {
    $item = Get-Item -LiteralPath $script:HistoryFile -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    "$($item.Length)|$($item.LastWriteTimeUtc.Ticks)"
}

# Re-read only when the file changed, which also picks up jumps made in other shells.
function Update-HobHistory {
    $stamp = Get-HobHistoryStamp
    if ($stamp -eq $script:HistoryStamp) { return }
    $history = @{}
    if ($stamp) {
        foreach ($line in [IO.File]::ReadLines($script:HistoryFile)) {
            $fields = $line.Split("`t")
            $ticks = 0L
            if ($fields.Count -lt 3 -or -not [long]::TryParse($fields[0], [ref]$ticks)) { continue }
            if (-not $history.ContainsKey($fields[2])) { $history[$fields[2]] = New-Object System.Collections.Generic.List[long] }
            $history[$fields[2]].Add($ticks)
        }
    }
    $script:History = $history
    $script:HistoryStamp = $stamp
}

# One line per jump: when, how, where, and for picker jumps which row was chosen and what was typed.
# The last two are what E6 replays to check how often the intended place was already on top.
function Add-HobVisit {
    param([string]$Path, [string]$How, [int]$PickIndex, [string]$Query)
    if ($env:HOB_NO_HISTORY) { return }
    $now = [DateTime]::UtcNow.Ticks
    $line = @($now, $How, $Path, $PickIndex, ($Query -replace '[\t\r\n]', ' ')) -join "`t"
    try {
        Update-HobHistory
        $folder = Split-Path -Parent $script:HistoryFile
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder) }
        [IO.File]::AppendAllText($script:HistoryFile, "$line`n")
        if (-not $script:History.ContainsKey($Path)) { $script:History[$Path] = New-Object System.Collections.Generic.List[long] }
        $script:History[$Path].Add($now)
        $script:HistoryStamp = Get-HobHistoryStamp
    }
    catch {
        if (-not $script:HistoryWarned) { Write-Warning "hob: could not record history in $($script:HistoryFile) ($_)" }
        $script:HistoryWarned = $true
    }
}

# zoxide-style buckets: a visit counts for less the older it gets, so habits and recent work both surface.
function Get-HobFrecency {
    param([string]$Path, [long]$Now)
    $visits = $script:History[$Path]
    if (-not $visits) { return 0.0 }
    $score = 0.0
    $start = [Math]::Max(0, $visits.Count - 200)
    for ($i = $start; $i -lt $visits.Count; $i++) {
        $age = $Now - $visits[$i]
        if ($age -lt [TimeSpan]::TicksPerHour) { $score += 4 }
        elseif ($age -lt [TimeSpan]::TicksPerDay) { $score += 2 }
        elseif ($age -lt 7 * [TimeSpan]::TicksPerDay) { $score += 0.5 }
        else { $score += 0.25 }
    }
    $score
}

function Show-HobRecent {
    param($Model)
    Update-HobHistory
    $now = [DateTime]::UtcNow.Ticks
    $ranked = @($Model.Places | ForEach-Object {
            $visits = $script:History[$_.Path]
            if ($visits) { [pscustomobject]@{ Place = $_; Score = Get-HobFrecency $_.Path $now; Visits = $visits.Count; Last = $visits[$visits.Count - 1] } }
        } | Sort-Object @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Last'; Descending = $true })
    if (-not $ranked.Count) { "No history yet. Jumps are recorded in $($script:HistoryFile)"; return }
    '  score  visits  last      place'
    foreach ($r in $ranked | Select-Object -First 15) {
        $ago = [TimeSpan]::FromTicks($now - $r.Last)
        $last = if ($ago.TotalHours -lt 1) { "$([int]$ago.TotalMinutes)m ago" } elseif ($ago.TotalDays -lt 1) { "$([int]$ago.TotalHours)h ago" } else { "$([int]$ago.TotalDays)d ago" }
        '{0,7:0.##}  {1,6}  {2,-8}  {3,-16}{4}' -f $r.Score, $r.Visits, $last, $r.Place.Qualified, $r.Place.Path
    }
    ''
    "History: $($script:HistoryFile)"
}

function Test-HobInteractive {
    $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected
}

# Every space-separated term must appear somewhere in the place's qualified name or path. Places whose
# name starts with the first term rank first; within that, frecency decides.
function Select-HobPlaceMatch {
    param($Places, [string]$Query)
    Update-HobHistory
    $terms = @($Query -split '\s+' | Where-Object { $_ })
    $ignoreCase = [StringComparison]::OrdinalIgnoreCase
    $now = [DateTime]::UtcNow.Ticks
    $i = 0
    $scored = foreach ($place in $Places) {
        $i++
        $haystack = "$($place.Qualified) $($place.Path)"
        $missing = @($terms | Where-Object { $haystack.IndexOf($_, $ignoreCase) -lt 0 })
        if ($missing.Count) { continue }

        $rank = 3
        if (-not $terms.Count -or $place.Name.StartsWith($terms[0], $ignoreCase)) { $rank = 0 }
        elseif ($place.Name.IndexOf($terms[0], $ignoreCase) -ge 0) { $rank = 1 }
        elseif ($place.Qualified.IndexOf($terms[0], $ignoreCase) -ge 0) { $rank = 2 }

        $last = 0L
        $visits = $script:History[$place.Path]
        if ($visits) { $last = $visits[$visits.Count - 1] }
        [pscustomobject]@{ Place = $place; Rank = $rank; Score = (Get-HobFrecency $place.Path $now); Last = $last; Order = $i }
    }
    @($scored | Sort-Object Rank, @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Last'; Descending = $true }, Order | ForEach-Object Place)
}

function Write-HobPickerRow {
    param([int]$Top, [string]$Text, [int]$Width, [ConsoleColor]$Foreground, [ConsoleColor]$Background, [switch]$Highlight)
    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width - 3) + '...' }
    [Console]::SetCursorPosition(0, $Top)
    if ($Highlight) { Write-Host $Text.PadRight($Width) -NoNewline -ForegroundColor $Foreground -BackgroundColor $Background }
    else { Write-Host $Text.PadRight($Width) -NoNewline -ForegroundColor $Foreground }
}

# Drawn inline under the prompt rather than full-screen, and erased afterwards, so the scrollback keeps
# only the command you typed. Colours go through Write-Host so it works in conhost and Windows Terminal.
function Show-HobPicker {
    param($Places, [string]$Query = '', [scriptblock]$ReadKey = $script:ReadKey)

    $visible = [Math]::Max(1, [Math]::Min(10, [Math]::Min($Places.Count, [Console]::WindowHeight - 4)))
    $rows = $visible + 2
    $width = [Console]::WindowWidth - 1
    $nameWidth = [Math]::Min(24, (@($Places | ForEach-Object { $_.Qualified.Length }) | Measure-Object -Maximum).Maximum + 2)
    $normal = [Console]::ForegroundColor
    if ([int]$normal -lt 0) { $normal = [ConsoleColor]::Gray }

    Write-Host ("`n" * $rows) -NoNewline
    $top = [Console]::CursorTop - $rows
    $selected = 0
    $offset = 0
    $treatControlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    try {
        while ($true) {
            $hits = @(Select-HobPlaceMatch $Places $Query)
            $selected = [Math]::Max(0, [Math]::Min($selected, $hits.Count - 1))
            if ($selected -lt $offset) { $offset = $selected }
            if ($selected -ge $offset + $visible) { $offset = $selected - $visible + 1 }

            [Console]::CursorVisible = $false
            Write-HobPickerRow $top "to> $Query" $width Cyan
            for ($r = 0; $r -lt $visible; $r++) {
                $i = $offset + $r
                $text = ''
                if ($i -lt $hits.Count) { $text = '  ' + $hits[$i].Qualified.PadRight($nameWidth) + $hits[$i].Path }
                if ($i -eq $selected -and $hits.Count) { Write-HobPickerRow ($top + 1 + $r) ('>' + $text.Substring(1)) $width Black Cyan -Highlight }
                else { Write-HobPickerRow ($top + 1 + $r) $text $width $normal }
            }
            Write-HobPickerRow ($top + $rows - 1) "  $($hits.Count)/$($Places.Count)   Up/Down move   Enter jump   Esc cancel" $width DarkGray
            [Console]::SetCursorPosition([Math]::Min(4 + $Query.Length, $width), $top)
            [Console]::CursorVisible = $true

            $key = & $ReadKey
            $control = ($key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
            if ($control -and $key.Key -eq 'C') { return $null }
            if ($control -and $key.Key -eq 'U') { $Query = ''; $selected = 0; continue }
            if ($control -and $key.Key -eq 'N') { $selected++; continue }
            if ($control -and $key.Key -eq 'P') { $selected--; continue }
            switch ($key.Key) {
                'Enter' { if ($hits.Count) { return [pscustomobject]@{ Place = $hits[$selected]; Index = $selected; Query = $Query } } }
                'Escape' { return $null }
                'UpArrow' { $selected-- }
                'DownArrow' { $selected++ }
                'PageUp' { $selected -= $visible }
                'PageDown' { $selected += $visible }
                'Backspace' {
                    if ($Query.Length) { $Query = $Query.Substring(0, $Query.Length - 1) }
                    $selected = 0
                }
                default {
                    if (-not [char]::IsControl($key.KeyChar)) { $Query += $key.KeyChar; $selected = 0 }
                }
            }
        }
    }
    finally {
        for ($r = 0; $r -lt $rows; $r++) { Write-HobPickerRow ($top + $r) '' $width $normal }
        [Console]::SetCursorPosition(0, $top)
        [Console]::CursorVisible = $true
        [Console]::TreatControlCAsInput = $treatControlC
    }
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
    if (-not $Words.Count) { Write-HobError 'usage: hob naive <place>'; return }
    $place = Resolve-HobPlace $Model $Words
    if (-not $place) { return }
    $dir = $place.Path
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
    foreach ($plugin in $Model.Plugins) {
        Show-HobPlugin $plugin
        ''
    }
    'Built-ins'
    foreach ($name in $script:Builtins.Keys) { Format-HobRow $name $script:Builtins[$name] 2 }
}

function Show-HobPlaces {
    param($Model)
    'Places: h to <name>, or h to <plugin> <name> when a name is shared'
    foreach ($plugin in $Model.Plugins) {
        $locations = @($plugin.Children | Where-Object Kind -eq 'location')
        if (-not $plugin.Root -and -not $locations.Count) { continue }
        $detail = $plugin.Description
        if ($plugin.Root) { $detail = $plugin.Root }
        Format-HobRow $plugin.Name $detail 2
        foreach ($location in $locations) { Format-HobRow $location.Name $location.Path 4 }
    }
}

# Same value<TAB>description protocol the real core will expose, so adapters stay thin.
function Get-HobCompletion {
    param($Model, [string]$Partial, [string[]]$Words)
    $entries = $Model.Top
    for ($i = 0; $i -lt $Words.Count; $i++) {
        $entry = (Find-HobEntry $entries $Words[$i]).Entry
        if ($entry -and $entry.Kind -eq 'plugin') { $entries = $entry.Children; continue }
        if ($entry -and $entry.Kind -eq 'builtin' -and $script:PlaceBuiltins -contains $entry.Name) {
            Get-HobPlaceCompletion $Model $Partial @($Words | Select-Object -Skip ($i + 1))
        }
        return
    }
    foreach ($entry in @($entries | Where-Object { $_.Name -like "$([WildcardPattern]::Escape($Partial))*" })) {
        "$($entry.Name)`t$($entry.Description)"
    }
}

function Get-HobPlaceCompletion {
    param($Model, [string]$Partial, [string[]]$Words)
    $pattern = "$([WildcardPattern]::Escape($Partial))*"
    if ($Words.Count -eq 0) {
        foreach ($place in $Model.Places) {
            if ($place.Name -like $pattern -or $place.Qualified -like $pattern) { "$($place.Completion)`t$($place.Path)" }
        }
    }
    elseif ($Words.Count -eq 1) {
        $plugin = (Find-HobEntry $Model.Plugins $Words[0]).Entry
        if (-not $plugin) { return }
        foreach ($location in @($plugin.Children | Where-Object { $_.Kind -eq 'location' -and $_.Name -like $pattern })) {
            "$($location.Name)`t$($location.Path)"
        }
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
    if ($words[0] -eq '__shortcuts') { $model.Plugins | ForEach-Object Name; return }

    $resolved = Resolve-HobWords $model.Top $words
    if (-not $resolved) { return }
    $entry = $resolved.Entry
    switch ($entry.Kind) {
        'builtin' {
            switch ($entry.Name) {
                'list' { Show-HobList $model }
                'back' {
                    try { Pop-Location -StackName hob -ErrorAction Stop }
                    catch { Write-HobError 'nothing to go back to' }
                }
                'naive' { Invoke-HobNaive $model $resolved.Rest }
                'recent' { Show-HobRecent $model }
                default {
                    $rest = $resolved.Rest
                    $interactive = Test-HobInteractive
                    if ($rest.Count -and $rest[0] -in '--list', '-l') { Show-HobPlaces $model; return }
                    if (-not $rest.Count -and -not $interactive) { Show-HobPlaces $model; return }

                    if ($rest.Count) {
                        $place = Resolve-HobPlace $model $rest -Quiet:$interactive
                        if ($place) { Invoke-HobJump $place 'to' -Query ($rest -join ' '); return }
                        if (-not $interactive) { return }
                    }
                    $pick = Show-HobPicker $model.Places ($rest -join ' ')
                    if (-not $pick) { $global:LASTEXITCODE = 1; return }
                    Invoke-HobJump $pick.Place 'picker' $pick.Index $pick.Query
                }
            }
        }
        'command' { Invoke-HobCommand $entry $resolved.Rest }
        default { Invoke-HobJump $entry }
    }
}

Export-ModuleMember -Function hob
