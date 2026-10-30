# In-process core for the ergonomics spike, loaded by the generated hob.ps1 on PATH, which PowerShell runs
# inside the calling session. Jumps resolve here because starting any process costs ~70 ms on this
# EDR-scanned machine. Plugin commands that are separate programs cannot change their parent's directory,
# so they move the shell through the directives file instead.
param([bool]$FlatPlaces = $false)

$script:SpikeDir = $PSScriptRoot
$script:PluginsDir = Join-Path $PSScriptRoot 'plugins'
$script:TemplatesDir = Join-Path $PSScriptRoot 'templates'
$script:FlatPlaces = $FlatPlaces
$script:Builtins = [ordered]@{
    list   = 'Show everything hob knows'
    to     = 'Jump to a place: hob to <place> or hob to <plugin> <place>'
    cd     = 'Same as to'
    path   = 'Print a place''s folder instead of going there, e.g. code (hob path spike)'
    back   = 'Go back to where the last jump came from'
    recent = 'Places ranked by how often and how recently you go there'
    update = 'Update hob to the latest release (installed copies only)'
    naive  = 'Try to cd from inside a child process, to watch it fail'
}
$script:PlaceBuiltins = @('to', 'cd', 'path', 'naive')
$script:SettingsFile = $env:HOB_SPIKE_SETTINGS
if (-not $script:SettingsFile) { $script:SettingsFile = Join-Path $env:USERPROFILE '.hob\settings.json' }
$script:BinDir = $env:HOB_SPIKE_BIN
if (-not $script:BinDir) { $script:BinDir = Join-Path $env:USERPROFILE '.hob\bin' }
$script:UserPluginsDir = Join-Path (Split-Path -Parent $script:SettingsFile) 'plugins'
$script:ForceWrite = $false
# A file on PATH cannot shadow these: cmd runs its built-in commands first.
$script:CmdInternal = @('assoc', 'break', 'call', 'cd', 'chdir', 'cls', 'color', 'copy', 'date', 'del', 'dir', 'echo', 'endlocal',
    'erase', 'exit', 'for', 'ftype', 'goto', 'if', 'md', 'mkdir', 'mklink', 'move', 'path', 'pause', 'popd', 'prompt', 'pushd',
    'rd', 'rem', 'ren', 'rename', 'rmdir', 'set', 'setlocal', 'shift', 'start', 'time', 'title', 'type', 'ver', 'verify', 'vol')
$script:ReadKey = { [Console]::ReadKey($true) }
# Machine-local and outside the repo: it records where you go, which is nobody else's business.
$script:HistoryFile = $env:HOB_SPIKE_HISTORY
if (-not $script:HistoryFile) { $script:HistoryFile = Join-Path $env:USERPROFILE '.hob\history.tsv' }
$script:History = @{}
$script:HistoryStamp = $null
$script:HistoryWarned = $false
$script:IndexFile = $env:HOB_SPIKE_INDEX
if (-not $script:IndexFile) { $script:IndexFile = Join-Path $env:USERPROFILE '.hob\index.txt' }
$script:IndexWarned = $false
$script:EnvNamePattern = '^[A-Za-z_][A-Za-z0-9_]*$'
# Refused in every shell for consistency: bash runs or re-reads these, which would turn a value into code.
$script:EnvDenyPattern = '^(PROMPT_COMMAND|PS[0-4]|ENV|BASH_ENV|BASH_FUNC_.*|BASHOPTS|SHELLOPTS|IFS)$'
$script:Model = $null
$script:ModelStamp = $null

function Write-HobError {
    param([string]$Message)
    [Console]::Error.WriteLine("hob: $Message")
    $global:LASTEXITCODE = 1
}

function Get-HobRoots {
    param($Settings)
    # LOCALAPPDATA\Temp rather than $env:TEMP, which can be an 8.3 short path.
    $temp = Join-Path $env:LOCALAPPDATA 'Temp'
    if (-not (Test-Path -LiteralPath $temp)) { $temp = [IO.Path]::GetTempPath() }
    $roots = @{
        home = $HOME
        temp = $temp
        git  = Join-Path $HOME 'Documents\git'
    }
    # {hob} is the repository, which only exists when running from a checkout rather than an install.
    $repo = [IO.Path]::GetFullPath((Join-Path $script:SpikeDir '..\..'))
    if (Test-Path -LiteralPath (Join-Path $repo '.git')) { $roots.hob = $repo }
    foreach ($name in $Settings.roots.Keys) { $roots[$name] = [Environment]::ExpandEnvironmentVariables($Settings.roots[$name]) }
    $roots
}

# Your own plugin folders come first so a plugin of yours can replace a built-in one with the same name.
# Built-ins live in the install folder, which an update replaces, so nothing of yours belongs there.
# These run on every command to check whether plugins changed, so they call .NET directly: PowerShell 7's
# file cmdlets made the check cost ~36 ms a call, against ~12 ms in Windows PowerShell.
function Get-HobPluginCandidates {
    param($Settings)
    $sources = New-Object System.Collections.Generic.List[string]
    $all = @($Settings.pluginPaths | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }) + $script:UserPluginsDir + $script:PluginsDir
    foreach ($path in $all) { if ($path -and -not $sources.Contains($path)) { $sources.Add($path) } }
    $sources
}

function Get-HobPluginSources {
    param($Settings)
    foreach ($path in Get-HobPluginCandidates $Settings) { if ([IO.Directory]::Exists($path)) { $path } }
}

function Get-HobPluginManifests {
    param($Settings)
    foreach ($source in Get-HobPluginSources $Settings) {
        foreach ($dir in [IO.Directory]::GetDirectories($source)) {
            $manifest = [IO.Path]::Combine($dir, 'plugin.json')
            if ([IO.File]::Exists($manifest)) { $manifest }
        }
    }
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

# Everything whose change should rebuild the model: the settings, each manifest, and each plugin source
# folder, whose timestamp changes when a plugin folder is added or removed. bash reads the same list from
# the index to decide when to rebuild it.
function Get-HobWatchList {
    $settings = Get-HobSettings
    $paths = New-Object System.Collections.Generic.List[string]
    $paths.Add($script:SettingsFile)
    foreach ($source in Get-HobPluginCandidates $settings) {
        # A plugin folder that does not exist yet is watched through its nearest existing parent, whose
        # timestamp changes when the folder is created.
        $watch = $source
        while ($watch -and -not [IO.Directory]::Exists($watch)) { $watch = [IO.Path]::GetDirectoryName($watch) }
        if ($watch -and -not $paths.Contains($watch)) { $paths.Add($watch) }
    }
    foreach ($manifest in Get-HobPluginManifests $settings) { $paths.Add($manifest) }
    $paths
}

function Get-HobModelStamp {
    $parts = foreach ($path in Get-HobWatchList) {
        if ([IO.File]::Exists($path)) { "$path|$([IO.File]::GetLastWriteTimeUtc($path).Ticks)" }
        elseif ([IO.Directory]::Exists($path)) { "$path|$([IO.Directory]::GetLastWriteTimeUtc($path).Ticks)" }
    }
    $parts -join ';'
}

# Manifests are re-read only when one changes, so edits are live without paying the parse on every call.
function Get-HobModel {
    $stamp = Get-HobModelStamp
    if ($script:Model -and $stamp -eq $script:ModelStamp) { return $script:Model }

    $settings = Get-HobSettings
    $roots = Get-HobRoots $settings
    $plugins = @()
    foreach ($manifestPath in Get-HobPluginManifests $settings) {
        $dir = Get-Item -LiteralPath (Split-Path -Parent $manifestPath)
        try {
            $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -ErrorAction Stop
            $earlier = @($plugins | Where-Object Name -eq $manifest.name)
            if ($earlier.Count) {
                Write-Warning "hob: ignored $manifestPath because '$($manifest.name)' is already provided by $($earlier[0].Dir)"
                continue
            }
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

    # Every place from every plugin, so `hob to` can search them all. A plugin's root is a place named after it.
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
    try { Write-HobIndex $script:Model }
    catch {
        if (-not $script:IndexWarned) { Write-Warning "hob: could not write the cmd/bash index to $($script:IndexFile) ($_)" }
        $script:IndexWarned = $true
    }
    $script:Model
}

# Cached until the file changes: every command checks whether plugins changed, and parsing JSON each time
# was a visible share of a jump.
function Get-HobSettings {
    $exists = [IO.File]::Exists($script:SettingsFile)
    $stamp = if ($exists) { [IO.File]::GetLastWriteTimeUtc($script:SettingsFile).Ticks } else { 'none' }
    if ($script:SettingsCache -and $stamp -eq $script:SettingsCacheStamp) { return $script:SettingsCache }

    $settings = @{ alias = 'hb'; shortcuts = $true; pluginPaths = @(); roots = @{} }
    if ($exists) {
        $file = $null
        try { $file = Get-Content -Raw -LiteralPath $script:SettingsFile | ConvertFrom-Json -ErrorAction Stop }
        catch { Write-Warning "hob: ignored $($script:SettingsFile), which is not valid JSON ($_)" }
        if ($file) {
            if ($null -ne $file.alias) { $settings.alias = [string]$file.alias }
            if ($null -ne $file.shortcuts) { $settings.shortcuts = [bool]$file.shortcuts }
            if ($null -ne $file.pluginPaths) { $settings.pluginPaths = @($file.pluginPaths | ForEach-Object { [string]$_ }) }
            if ($null -ne $file.roots) { foreach ($p in $file.roots.PSObject.Properties) { $settings.roots[$p.Name] = [string]$p.Value } }
        }
    }
    $script:SettingsCache = $settings
    $script:SettingsCacheStamp = $stamp
    $settings
}

# Get-Command is far too slow for this (over a second in PowerShell 7 even with -ListImported, ~60 ms per
# name for a PATH search), so the alias and function drives, loaded modules and PATH are checked directly.
function Test-HobNameTaken {
    param([string]$Name)
    if ($script:CmdInternal -contains $Name) { return $true }
    if (Test-Path -LiteralPath "Alias:\$Name") { return $true }
    if (Test-Path -LiteralPath "Function:\$Name") { return $true }
    foreach ($module in Get-Module) {
        if ($module.Name -ne 'hob' -and $module.ExportedCommands.ContainsKey($Name)) { return $true }
    }
    # Both sides go through GetFullPath because on .NET Framework it expands 8.3 short names, so a raw
    # comparison could miss hob's own folder and report hob's own commands as clashes.
    $bin = [IO.Path]::GetFullPath($script:BinDir).TrimEnd('\')
    foreach ($dir in $env:PATH.Split(';')) {
        $dir = $dir.Trim('"')
        if (-not $dir) { continue }
        try { if ([IO.Path]::GetFullPath($dir).TrimEnd('\') -eq $bin) { continue } } catch { continue }
        $dir = $dir.TrimEnd('\')
        foreach ($ext in @('') + $env:PATHEXT.Split(';')) {
            try { if ([IO.File]::Exists([IO.Path]::Combine($dir, $Name + $ext))) { return $true } }
            catch { break }
        }
    }
    $false
}

function Write-HobFileIfChanged {
    param([string]$Path, [string]$Content, [Text.Encoding]$Encoding)
    if ((Test-Path -LiteralPath $Path) -and [IO.File]::ReadAllText($Path) -eq $Content) { return }
    [IO.File]::WriteAllText($Path, $Content, $Encoding)
}

# One file per shell for every command name, in a folder on PATH, so no shell needs any setup: PowerShell
# prefers name.ps1 and runs it inside the session, cmd runs name.cmd inside the window, and Git Bash runs
# the extension-less name as a separate process. Startup files are never touched.
# hob-cli.exe renders the same templates by the same rules (templates\README.md), so whichever of the two
# last wrote a command, the other sees identical content and leaves it alone.
function Get-HobShimFiles {
    param([string]$Name, [string]$Prefix)
    $values = @{
        '{{PSM1}}'   = (Join-Path $script:SpikeDir 'hob.psm1').Replace("'", "''")
        '{{CMD}}'    = Join-Path $script:SpikeDir 'cmd\hob.cmd'
        '{{SH}}'     = ([regex]::Replace((Join-Path $script:SpikeDir 'bash\hob.sh'), '^([A-Za-z]):', { param($m) "/$($m.Groups[1].Value.ToLowerInvariant())" })).Replace('\', '/').Replace("'", "'\''")
        '{{PREFIX}}' = $Prefix
    }
    $render = {
        param([string]$Template, [string]$NewLine)
        $text = [IO.File]::ReadAllText((Join-Path $script:TemplatesDir $Template)).Replace("`r`n", "`n")
        foreach ($key in $values.Keys) { $text = $text.Replace($key, $values[$key]) }
        $text.Replace("`n", $NewLine)
    }
    @(
        @{ File = "$Name.ps1"; Text = (& $render 'shim.ps1' "`r`n"); Encoding = (New-Object Text.UTF8Encoding $true) }
        @{ File = "$Name.cmd"; Text = (& $render 'shim.cmd' "`r`n"); Encoding = (New-Object Text.UTF8Encoding $false) }
        @{ File = $Name; Text = (& $render 'shim.sh' "`n"); Encoding = (New-Object Text.UTF8Encoding $false) }
    )
}

function Write-HobBin {
    param($Model)
    $settings = Get-HobSettings
    $marker = 'Generated by hob; do not edit.'

    $names = [ordered]@{ hob = '' }
    if ($settings.alias) {
        if (Test-HobNameTaken $settings.alias) { Write-Warning "hob: no '$($settings.alias)' short name, because it would hide an existing command" }
        else { $names[$settings.alias] = '' }
    }
    if ($settings.shortcuts) {
        foreach ($plugin in $Model.Plugins) {
            if ($names.Contains($plugin.Name)) { continue }
            if (Test-HobNameTaken $plugin.Name) { Write-Warning "hob: no '$($plugin.Name)' shortcut, because it would hide an existing command"; continue }
            $names[$plugin.Name] = $plugin.Name
        }
    }

    if (-not (Test-Path -LiteralPath $script:BinDir)) { [void](New-Item -ItemType Directory -Path $script:BinDir) }
    $keep = @{}
    foreach ($name in $names.Keys) {
        foreach ($shim in Get-HobShimFiles $name $names[$name]) {
            Write-HobFileIfChanged (Join-Path $script:BinDir $shim.File) $shim.Text $shim.Encoding
            $keep[$shim.File] = $true
        }
    }

    # Remove commands for plugins that no longer exist, but only files hob wrote.
    foreach ($file in Get-ChildItem -LiteralPath $script:BinDir -File) {
        if ($keep[$file.Name]) { continue }
        $head = (Get-Content -LiteralPath $file.FullName -TotalCount 3 -ErrorAction SilentlyContinue) -join "`n"
        if ($head -like "*$marker*") { Remove-Item -LiteralPath $file.FullName }
    }
}

# Edits the raw registry value rather than using [Environment]::SetEnvironmentVariable, which reads PATH
# expanded and writes it back as a plain string, silently baking in every %VARIABLE% reference.
function Set-HobUserPathEntry {
    param([string]$Entry, [switch]$Remove, [string]$KeyPath = 'Environment')
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($KeyPath)
    try {
        $raw = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        if ($raw) { $kind = $key.GetValueKind('Path') }
        $entries = @($raw.Split(';') | Where-Object { $_ })
        $present = @($entries | Where-Object { $_.TrimEnd('\') -eq $Entry.TrimEnd('\') }).Count -gt 0
        if ($Remove) {
            if (-not $present) { return $false }
            $entries = @($entries | Where-Object { $_.TrimEnd('\') -ne $Entry.TrimEnd('\') })
        }
        else {
            if ($present) { return $false }
            $entries += $Entry
        }
        $key.SetValue('Path', ($entries -join ';'), $kind)
    }
    finally { $key.Dispose() }
    if ($KeyPath -eq 'Environment') {
        # Writing a user variable through .NET broadcasts WM_SETTINGCHANGE, which is what tells Explorer, and
        # so newly opened terminals, that PATH changed. A throwaway variable avoids needing native code for it.
        [Environment]::SetEnvironmentVariable('HOB_SPIKE_REFRESH', '1', 'User')
        [Environment]::SetEnvironmentVariable('HOB_SPIKE_REFRESH', $null, 'User')
    }
    $true
}

function Update-HobFiles {
    $script:ForceWrite = $true
    try {
        $script:Model = $null
        $script:ModelStamp = $null
        [void](Get-HobModel)
    }
    finally { $script:ForceWrite = $false }
}

function Get-HobShimCompletion {
    param($CommandAst, [string]$WordToComplete, [string]$Prefix)
    $words = @()
    if ($Prefix) { $words += $Prefix }
    foreach ($element in @($CommandAst.CommandElements | Select-Object -Skip 1)) {
        if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $words += $element.Value }
        else { $words += $element.Extent.Text }
    }
    if ($WordToComplete -and $words.Count) { $words = @($words | Select-Object -First ($words.Count - 1)) }
    foreach ($line in Get-HobCompletion (Get-HobModel) $WordToComplete $words) {
        $value, $description = $line -split "`t", 2
        if (-not $description) { $description = $value }
        [System.Management.Automation.CompletionResult]::new($value, $value, 'ParameterValue', $description)
    }
}

function Get-HobPrefixes {
    param([string]$Name)
    $lower = $Name.ToLowerInvariant()
    for ($i = 1; $i -le $lower.Length; $i++) { $lower.Substring(0, $i) }
}

# cmd and bash cannot parse manifests or reimplement prefix matching cheaply, so every spelling hob accepts
# is resolved here, with the same functions the PowerShell path uses, and written out as a lookup table.
function Write-HobIndex {
    param($Model)
    # The header identifies the manifests and module it was built from, so a new shell can skip rebuilding it,
    # and bash can tell from the first line alone whether to reload.
    $module = Get-Item -LiteralPath (Join-Path $script:SpikeDir 'hob.psm1')
    $sha = [Security.Cryptography.SHA256]::Create()
    $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$($script:ModelStamp);$($module.LastWriteTimeUtc.Ticks)"))
    $header = "# hob spike index $(-join ($digest[0..7] | ForEach-Object { $_.ToString('x2') })). Generated by hob.psm1; do not edit."
    if (-not $script:ForceWrite -and (Test-Path -LiteralPath $script:IndexFile) -and (Test-Path -LiteralPath (Join-Path $script:BinDir 'hob.ps1'))) {
        $reader = New-Object IO.StreamReader($script:IndexFile)
        try { if ($reader.ReadLine() -eq $header) { return } } finally { $reader.Dispose() }
    }
    Write-HobBin $Model

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($header)
    $clean = { param([string]$s) ($s -replace '[|\r\n]', '/') }

    foreach ($entry in $Model.Top | Where-Object { $_.Kind -in 'builtin', 'plugin' }) { $lines.Add("top|$($entry.Name)|$(& $clean $entry.Description)") }

    $seen = @{}
    foreach ($place in $Model.Places) {
        foreach ($key in Get-HobPrefixes $place.Name) {
            if ($seen[$key]) { continue }
            $seen[$key] = $true
            $found = Find-HobEntry $Model.Places $key
            if ($found.Entry) { $lines.Add("to|$key|$($found.Entry.Path)") }
            elseif ($found.Candidates.Count -gt 1) { $lines.Add("to?|$key|$(($found.Candidates | ForEach-Object Qualified) -join ', ')") }
        }
    }
    foreach ($plugin in $Model.Plugins) {
        $locations = @($plugin.Children | Where-Object Kind -eq 'location')
        foreach ($pluginKey in Get-HobPrefixes $plugin.Name) {
            if ((Find-HobEntry $Model.Plugins $pluginKey).Entry -ne $plugin) { continue }
            foreach ($location in $locations) {
                foreach ($locationKey in Get-HobPrefixes $location.Name) {
                    $key = "$pluginKey $locationKey"
                    if ($seen[$key]) { continue }
                    $seen[$key] = $true
                    $found = Find-HobEntry $locations $locationKey
                    if ($found.Entry) { $lines.Add("to|$key|$($found.Entry.Path)") }
                    elseif ($found.Candidates.Count -gt 1) { $lines.Add("to?|$key|$(($found.Candidates | ForEach-Object Qualified) -join ', ')") }
                }
            }
        }
    }

    foreach ($plugin in $Model.Plugins) {
        foreach ($key in Get-HobPrefixes $plugin.Name) {
            $found = Find-HobEntry $Model.Top $key
            if ($found.Entry -eq $plugin) { $lines.Add("plug|$key|$($plugin.Name)") }
            elseif (-not $found.Entry -and $found.Candidates.Count -gt 1 -and -not $seen["plug? $key"]) {
                $seen["plug? $key"] = $true
                $lines.Add("plug?|$key|$(($found.Candidates | ForEach-Object Name) -join ', ')")
            }
        }
        $lines.Add("root|$($plugin.Name)|$($plugin.Root)")
        $lines.Add("short|$($plugin.Name)|")
        $childSeen = @{}
        foreach ($child in $plugin.Children) {
            $lines.Add("sub|$($plugin.Name)|$($child.Name)")
            foreach ($childKey in Get-HobPrefixes $child.Name) {
                if ($childSeen[$childKey]) { continue }
                $childSeen[$childKey] = $true
                $found = Find-HobEntry $plugin.Children $childKey
                $key = "$($plugin.Name) $childKey"
                if (-not $found.Entry) {
                    if ($found.Candidates.Count -gt 1) { $lines.Add("child?|$key|$(($found.Candidates | ForEach-Object Name) -join ', ')") }
                }
                elseif ($found.Entry.Kind -eq 'location') { $lines.Add("go|$key|$($found.Entry.Path)") }
                elseif ($found.Entry.Run.Count -eq 1) { $lines.Add("run|$key|$($found.Entry.Run[0])") }
            }
        }
    }

    foreach ($place in $Model.Places) {
        $lines.Add("list|$($place.Qualified)|$($place.Path)")
        $lines.Add("tocomp|$($place.Completion)|$($place.Name)")
    }
    foreach ($path in @(Get-HobWatchList) + (Join-Path $script:SpikeDir 'hob.psm1')) { $lines.Add("watch|$path|") }

    $folder = Split-Path -Parent $script:IndexFile
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder) }
    [IO.File]::WriteAllText($script:IndexFile, (($lines -join "`n") + "`n"))
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
                $suggestions = ($places | ForEach-Object { "'hob to $($_.Qualified)'" }) -join ' or '
                if ($places.Count -eq 1) { $suggestions = "'hob to $($Words[$i])'" }
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
        Write-HobError "'$token' could be: $names. Be more specific, for example 'hob to $($found.Candidates[0].Qualified)'."
    }
    else { Write-HobError "no place called '$($Words -join ' ')'. 'hob to' lists them all." }
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
    $item = New-Object IO.FileInfo $script:HistoryFile
    if (-not $item.Exists) { return $null }
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

# One action per line, "verb value", because cmd and bash can split that with builtins but cannot parse
# JSON. Values cannot contain newlines, and Windows paths cannot contain the characters that would matter.
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
                    catch { Write-Warning 'hob: nothing to go back to' }
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

function Invoke-HobCommand {
    param($Command, [string[]]$Extra)
    $file = [IO.Path]::GetTempFileName()
    $env:HOB_DIRECTIVES = $file
    $env:HOB_PLUGIN_DIR = $Command.Plugin.Dir
    $code = 0
    try {
        $exe = $Command.Run[0]
        $runArgs = @($Command.Run | Select-Object -Skip 1) + @($Extra)
        if ($exe -like '*.ps1') {
            # Plugins are trusted, so PowerShell commands run in this session (~5 ms rather than 200 ms+ for a
            # new process) and may move it directly. A move is re-recorded on hob's stack so `hob back` undoes it.
            $before = Get-Location
            $global:LASTEXITCODE = 0
            & $exe @runArgs
            if (-not $?) { $code = 1 } else { $code = $LASTEXITCODE }
            $after = Get-Location
            if ($after.Path -ne $before.Path) {
                Set-Location -LiteralPath $before.Path
                Push-Location -LiteralPath $after.Path -StackName hob
            }
        }
        else {
            & $exe @runArgs
            $code = $LASTEXITCODE
        }
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
    'Places: hob to <name>, or hob to <plugin> <name> when a name is shared'
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
                'update' {
                    $cli = Join-Path $script:SpikeDir 'hob-cli.exe'
                    if (-not (Test-Path -LiteralPath $cli)) { Write-HobError 'this hob runs from a source checkout, so update it with git pull'; return }
                    & $cli update @($resolved.Rest)
                    $global:LASTEXITCODE = $LASTEXITCODE
                }
                default {
                    $rest = $resolved.Rest
                    $interactive = Test-HobInteractive
                    $printOnly = $entry.Name -eq 'path'
                    if ($rest.Count -and $rest[0] -in '--list', '-l') { Show-HobPlaces $model; return }
                    if (-not $rest.Count -and -not $interactive) {
                        if ($printOnly) { Write-HobError 'usage: hob path <place>' } else { Show-HobPlaces $model }
                        return
                    }

                    $place = $null
                    $how = 'to'
                    $index = -1
                    $query = $rest -join ' '
                    if ($rest.Count) {
                        $place = Resolve-HobPlace $model $rest -Quiet:$interactive
                        if (-not $place -and -not $interactive) { return }
                    }
                    if (-not $place) {
                        $pick = Show-HobPicker $model.Places $query
                        if (-not $pick) { $global:LASTEXITCODE = 1; return }
                        $place, $how, $index, $query = $pick.Place, 'picker', $pick.Index, $pick.Query
                    }
                    if ($printOnly) {
                        $place.Path
                        Add-HobVisit $place.Path 'path' $index $query
                        return
                    }
                    Invoke-HobJump $place $how $index $query
                }
            }
        }
        'command' { Invoke-HobCommand $entry $resolved.Rest }
        default { Invoke-HobJump $entry }
    }
}

# Nothing is exported: a global `hob` function would take precedence over hob.ps1 on PATH, and with it the
# completer declared there. The generated scripts call in through the module object instead.
Export-ModuleMember -Function @()
