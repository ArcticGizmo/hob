<#
.SYNOPSIS
    Installs hob on Windows from a GitHub release.

.DESCRIPTION
    Downloads the Velopack installer (Hob-win-Setup.exe) for a release, verifies it against the
    SHA256SUMS.txt published alongside it, and runs it. Every later update is Velopack's job, via
    `hob update`.

    Download it, read it, then run it. Do not pipe it into Invoke-Expression: a script you have not read
    should not run in your session, and many endpoint protection products block that pattern anyway.

        Invoke-WebRequest https://raw.githubusercontent.com/ArcticGizmo/hob/main/install.ps1 -OutFile install-hob.ps1
        notepad install-hob.ps1
        .\install-hob.ps1

    A file saved by Invoke-WebRequest carries no mark-of-the-web, so it runs under the RemoteSigned
    execution policy, and the Setup.exe it downloads skips the SmartScreen prompt a browser download hits.

    KEEP THIS FILE PURE ASCII. It has no byte-order mark, so Windows PowerShell 5.1 decodes it with the
    system codepage. A UTF-8 em dash then arrives as characters ending in a curly closing quote, which
    PowerShell honours as a string delimiter, and the rest of the script mis-parses.

.PARAMETER Version
    Install a specific version (e.g. 0.1.0) instead of the latest release. A leading "v" is fine.

.PARAMETER Repo
    owner/name of the GitHub repository to install from, for a fork.

.EXAMPLE
    .\install-hob.ps1

.EXAMPLE
    .\install-hob.ps1 -Version 0.1.0
#>
#Requires -Version 5.1
param(
    [string] $Version,
    [string] $Repo = 'ArcticGizmo/hob'
)

function Install-Hob {
    [CmdletBinding()]
    param([string] $Version, [string] $Repo)

    $ErrorActionPreference = 'Stop'

    $SetupAsset = 'Hob-win-Setup.exe'
    $SumsAsset  = 'SHA256SUMS.txt'

    # --- Preflight -------------------------------------------------------------------------------------
    if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
        throw "hob ships a Windows build only. See $(Get-RepoUrl $Repo)."
    }
    if (-not [System.Environment]::Is64BitOperatingSystem) {
        throw 'hob ships as 64-bit only; this looks like a 32-bit Windows.'
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        Write-Warning 'ARM64 Windows detected. hob is x64-only, so hob-cli.exe will run under emulation.'
    }
    # Older Windows PowerShell hosts can still default to TLS 1.0, which api.github.com refuses outright.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    # --- Resolve the release ---------------------------------------------------------------------------
    $release = Get-HobRelease -Repo $Repo -Version $Version
    $tag     = $release.tag_name
    Write-Host "Installing hob $tag" -ForegroundColor Cyan

    # Looked up in the release metadata rather than guessed, so a release missing an asset fails here with
    # a clear reason instead of downloading a 404 page.
    $setupUrl = Get-AssetUrl -Release $release -Name $SetupAsset
    $sumsUrl  = Get-AssetUrl -Release $release -Name $SumsAsset

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("hob-install-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $work | Out-Null
    $keepWork = $false   # set if we bail out while the installer might still be reading from $work
    try {
        # --- Download ----------------------------------------------------------------------------------
        # Release assets are application/octet-stream, so on 5.1 .Content is a byte[], not a string, and
        # [string] on it would give "55 49 102 ..." which never matches a hash line.
        $raw   = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing).Content
        $sums  = if ($raw -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($raw) } else { [string]$raw }
        $want  = Get-ExpectedHash -Sums $sums -Name $SetupAsset -Tag $tag

        $setup = Join-Path $work $SetupAsset
        Save-File -Uri $setupUrl -OutFile $setup -Label $SetupAsset

        # --- Verify ------------------------------------------------------------------------------------
        # A mismatch means a truncated or corrupted transfer, a proxy that rewrote the payload, or
        # tampering. Never install either way.
        $got = (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash
        if ($got -ne $want) {
            Remove-Item -LiteralPath $setup -Force -ErrorAction SilentlyContinue
            throw @"
Checksum mismatch for $SetupAsset - refusing to install.
  expected  $want
  actual    $got
The download has been deleted. Retry; if it keeps failing, report it at $(Get-RepoUrl $Repo)/issues.
"@
        }
        Write-Host "  SHA-256 verified  $($want.ToLowerInvariant())" -ForegroundColor DarkGray

        # --- Install -----------------------------------------------------------------------------------
        # No admin rights: Velopack installs to %LOCALAPPDATA%\Hob and runs hob-cli's install hook, which
        # writes hob's commands and puts their folder on the USER PATH. Nothing writes the system PATH.
        #
        # Not `Start-Process -Wait`: that also waits for every descendant of Setup.exe, so it can hang.
        # Waiting on Setup's own handle returns as soon as the install itself is done.
        Write-Host 'Running the installer...'
        $psi = [System.Diagnostics.ProcessStartInfo]::new($setup)
        $psi.UseShellExecute = $true   # explicit: the default differs between Windows PowerShell and 7.x
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc) { throw "Could not start $SetupAsset." }

        # Bounded so a wedged installer (an antivirus prompt behind another window) reports something
        # instead of hanging the shell indefinitely.
        if (-not $proc.WaitForExit(10 * 60 * 1000)) {
            $keepWork = $true
            Write-Warning "The installer is still running after 10 minutes - leaving it to finish on its own. Delete $work once hob has installed."
            return
        }
        if ($proc.ExitCode -ne 0) {
            throw "The hob installer exited with code $($proc.ExitCode)."
        }
    }
    finally {
        if (-not $keepWork) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # --- PATH --------------------------------------------------------------------------------------
    # The install hook has already done this; repeating it is a no-op that prints the result where the
    # user can see it, rather than only in hob-cli.log.
    $hobCli = Join-Path $env:LOCALAPPDATA 'Hob\current\hob-cli.exe'
    if (-not (Test-Path -LiteralPath $hobCli)) {
        throw "Installed, but $hobCli is missing, so hob can't be put on your PATH."
    }
    Write-Host ''
    Write-Host 'Checking hob is on your user PATH...'
    & $hobCli setup
    $setupOk = ($LASTEXITCODE -eq 0)

    Write-Host ''
    Write-Host "hob $tag is installed." -ForegroundColor Green
    if ($setupOk) {
        Write-Host '  Open a NEW terminal (so it picks up the updated PATH) and run:  hob' -ForegroundColor DarkGray
    }
    else {
        Write-Warning "hob-cli setup reported a problem (above). Retry with:  & '$hobCli' setup"
    }
    Write-Host '  Update later with:  hob update' -ForegroundColor DarkGray
}

function Get-RepoUrl { param([string] $Repo) "https://github.com/$Repo" }

# Uses $env:GITHUB_TOKEN when present, which only matters behind a shared IP that has used up the anonymous
# 60 requests/hour. It is not sent when downloading assets (see Save-File).
function Get-HobRelease {
    param([string] $Repo, [string] $Version)

    $headers = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'hob-install.ps1' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $uri  = "https://api.github.com/repos/$Repo/releases/latest"
        $what = 'the latest release'
    }
    else {
        $tag  = if ($Version.StartsWith('v')) { $Version } else { "v$Version" }
        $uri  = "https://api.github.com/repos/$Repo/releases/tags/$tag"
        $what = "release $tag"
    }

    try {
        return Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing
    }
    catch {
        throw "Could not look up $what of $Repo. $($_.Exception.Message)"
    }
}

function Get-AssetUrl {
    param($Release, [string] $Name)

    $asset = $Release.assets | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $asset) {
        throw @"
Release $($Release.tag_name) has no $Name asset, so this installer can't verify or install it.
Install $($Release.tag_name) by hand from $($Release.html_url), or re-run without -Version to take the
latest release.
"@
    }
    return $asset.browser_download_url
}

# A manifest that lists other files but not this one is a build error, and treating it as "nothing to
# check" would quietly defeat the point, so it throws.
function Get-ExpectedHash {
    param([string] $Sums, [string] $Name, [string] $Tag)

    foreach ($line in $Sums -split "`r?`n") {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $Name) {
            return $Matches[1].ToUpperInvariant()   # Get-FileHash returns upper-case hex
        }
    }
    throw "SHA256SUMS.txt for $Tag has no entry for $Name, so the download can't be verified."
}

# No Authorization header: asset URLs redirect to a pre-signed objects.githubusercontent.com URL that
# rejects requests carrying one.
function Save-File {
    param([string] $Uri, [string] $OutFile, [string] $Label)

    $req = [System.Net.WebRequest]::CreateHttp($Uri)
    $req.UserAgent = 'hob-install.ps1'
    $req.Timeout = 60000
    # Per read, not for the whole transfer, so this bounds a stalled connection, not a slow one.
    $req.ReadWriteTimeout = 60000

    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        $shown = -1
        $in  = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($OutFile)
        try {
            $buffer = [byte[]]::new(131072)
            $read = 0
            while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $out.Write($buffer, 0, $n)
                $read += $n
                if ($total -gt 0) {
                    # Throttled to whole-percent changes: Write-Progress per 128 KB chunk is slow on 5.1.
                    $pct = [int](100 * $read / $total)
                    if ($pct -ne $shown) {
                        $shown = $pct
                        Write-Progress -Activity "Downloading $Label" `
                            -Status ("{0:N1} of {1:N1} MB" -f ($read / 1MB), ($total / 1MB)) -PercentComplete $pct
                    }
                }
            }
        }
        finally {
            $out.Dispose()
            $in.Dispose()
            Write-Progress -Activity "Downloading $Label" -Completed
        }
        if ($total -gt 0 -and (Get-Item -LiteralPath $OutFile).Length -ne $total) {
            throw "$Label downloaded incompletely ($((Get-Item -LiteralPath $OutFile).Length) of $total bytes)."
        }
    }
    finally {
        $resp.Dispose()
    }
    Write-Host ("  downloaded {0} ({1:N1} MB)" -f $Label, ((Get-Item -LiteralPath $OutFile).Length / 1MB))
}

Install-Hob -Version $Version -Repo $Repo
