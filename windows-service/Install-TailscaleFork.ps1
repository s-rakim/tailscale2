#Requires -Version 5.1
<#
.SYNOPSIS
    One command that swaps the official Tailscale app for your fork, built on
    top of the newest official Tailscale release, and keeps it up to date.

.DESCRIPTION
    Run it once from an Administrator PowerShell. It:
      1. Asks Tailscale's own update service (pkgs.tailscale.com) which version
         is the current stable release.
      2. Records your current settings (exit node, routes, hostname...) so it
         can show afterwards that nothing changed.
      3. Downloads that release's source from github.com/tailscale/tailscale,
         lays your fork's changes on top (windows-service\patches), and builds
         tailscale.exe and tailscaled.exe with a temporary Go toolchain and a
         portable Git, both checksum-checked and deleted when done.
      4. Puts everything in C:\Tailscale and runs Switch-ToFork.ps1: removes the
         official app and its tray GUI, installs the fork as the auto-start
         "Tailscale" service, and reuses your existing login.
      5. Turns off Tailscale's built-in auto-update. That updater can only
         install the official build, so it would silently replace your fork.
      6. Registers a scheduled task, "Tailscale fork update", that checks
         pkgs.tailscale.com every day and, when a new official release is out,
         rebuilds your fork on it and swaps the new files in. Your login and
         settings carry over; nothing happens if you're already current.
      7. Arms the wired adapter for Wake-on-LAN (skip with -SkipWakeOnLan) and
         prints a lag report (Tune-Tailscale.ps1 -ReportOnly).

    It never changes your exit node or routes. Login and settings live in
    C:\ProgramData\Tailscale, which is backed up before the official app is
    removed and carries over as-is.

.PARAMETER InstallDir
    Where the fork lives. Default C:\Tailscale.

.PARAMETER Ref
    Branch or tag of your fork to take the scripts and patches from. Default:
    main, falling back to the windows-one-command branch while its PR is open.

.PARAMETER Track
    Official release track to follow: stable (default) or unstable.

.PARAMETER SkipWakeOnLan
    Don't run Enable-WakeOnLan.ps1.

.PARAMETER NoUpdateTask
    Don't register the daily update task.

.PARAMETER Scheduled
    Used by the update task. Rebuilds only when the official release is newer
    than what's installed, and just swaps the two .exe files.

.PARAMETER Force
    With -Scheduled, rebuild even if already on the latest release.

.EXAMPLE
    # One line in an Administrator PowerShell, nothing to download first:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/s-rakim/tailscale2/windows-one-command/windows-service/Install-TailscaleFork.ps1)))
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Tailscale',
    [string]$Ref,
    [ValidateSet('stable', 'unstable')]
    [string]$Track = 'stable',
    [switch]$SkipWakeOnLan,
    [switch]$NoUpdateTask,
    [switch]$Scheduled,
    [switch]$Force
)

# This script is often run as a script block via irm, where "exit" would close
# the whole PowerShell window. So it uses throw for errors instead.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is far faster without the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 's-rakim/tailscale2'
$Upstream = 'tailscale/tailscale'
$FallbackRef = 'windows-one-command'
$TaskName = 'Tailscale fork update'
$versionFile = Join-Path $InstallDir 'upstream-version.txt'

# Windows PowerShell 5.1 turns a native program's stderr into errors when it's
# redirected, which ErrorActionPreference=Stop would make fatal. Run those
# calls with Continue instead.
function Invoke-Quiet([scriptblock]$Body) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Body } finally { $ErrorActionPreference = $old }
}

function Say([string]$msg) { Write-Host ""; Write-Host "=== $msg" -ForegroundColor Cyan }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Open PowerShell with 'Run as administrator' and run this again."
}

$officialDir = Join-Path $env:ProgramFiles 'Tailscale'
if ($InstallDir.TrimEnd('\') -like "$officialDir*") {
    throw "InstallDir can't be inside $officialDir; the official uninstaller deletes that folder."
}

$goArch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    default { throw "Unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE" }
}

if ($Scheduled) {
    New-Item -ItemType Directory $InstallDir -Force | Out-Null
    try { Start-Transcript -Path (Join-Path $InstallDir 'update.log') -Append | Out-Null } catch { }
}

# --- 1. Which official release is current? -------------------------------------

Say "Asking pkgs.tailscale.com for the latest $Track release"
$official = $null
try {
    $pkgs = Invoke-RestMethod "https://pkgs.tailscale.com/$Track/?mode=json&os=windows" -UseBasicParsing
    $official = @($pkgs.MSIsVersion, $pkgs.Version, $pkgs.TarballsVersion) |
        Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Select-Object -First 1
} catch {
    Write-Host "    pkgs.tailscale.com didn't answer: $($_.Exception.Message)"
}
if (-not $official -and $Track -eq 'stable') {
    # Same answer from the official GitHub releases, in case pkgs is unreachable.
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Upstream/releases/latest" -UseBasicParsing
    $official = $rel.tag_name.TrimStart('v')
}
if (-not $official) { throw "Couldn't find out the latest official Tailscale version." }
Write-Host "    latest official release: $official"

$installed = if (Test-Path $versionFile) { (Get-Content $versionFile -Raw).Trim() } else { $null }
if ($installed) { Write-Host "    your fork is built on:   $installed" }

if ($Scheduled -and -not $Force -and $installed -eq $official) {
    Write-Host "    already up to date, nothing to do."
    try { Stop-Transcript | Out-Null } catch { }
    return
}

# --- 2. Snapshot the settings we promise not to touch -------------------------

$watched = 'ExitNodeID', 'ExitNodeIP', 'ExitNodeAllowLANAccess', 'AutoExitNode',
           'AdvertiseRoutes', 'RouteAll', 'ControlURL', 'Hostname'

function Get-TsPrefs([string]$Exe) {
    if (-not $Exe -or -not (Test-Path $Exe)) { return $null }
    try {
        $raw = Invoke-Quiet { & $Exe debug prefs 2>$null | Out-String }
        if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) { return $null }
        return $raw | ConvertFrom-Json
    } catch { return $null }
}

function Show-Prefs($p) {
    foreach ($k in $watched) {
        $v = $p.$k
        if ($v -is [array]) { $v = ($v -join ', ') }
        if ("$v" -ne '') { Write-Host ("    {0,-24} {1}" -f $k, $v) }
    }
}

Say 'Recording your current settings'
$currentExe = @(
    (Join-Path $InstallDir 'tailscale.exe'),
    (Join-Path $officialDir 'tailscale.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$before = Get-TsPrefs $currentExe
if ($before) {
    Show-Prefs $before
} else {
    Write-Host "    (couldn't read settings; the service may not be running. Carrying on.)"
}

# --- 3. Download everything into a temp folder --------------------------------

$work = Join-Path $env:TEMP "tailscale-fork-build"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory $work | Out-Null

function Expand-Zip([string]$Zip, [string]$Dest) {
    New-Item -ItemType Directory $Dest -Force | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        & $tar -xf $Zip -C $Dest
        if ($LASTEXITCODE -ne 0) { throw "Couldn't extract $Zip" }
    } else {
        Expand-Archive $Zip $Dest -Force
    }
}

function Get-RepoZip([string]$RepoName, [string]$R, [string]$Name) {
    $zip = Join-Path $work "$Name.zip"
    Invoke-WebRequest "https://codeload.github.com/$RepoName/zip/$R" -OutFile $zip -UseBasicParsing
    $dest = Join-Path $work $Name
    Expand-Zip $zip $dest
    return (Get-ChildItem $dest -Directory | Select-Object -First 1).FullName
}

Say "Downloading your fork's scripts and changes from github.com/$Repo"
$candidates = if ($Ref) { @($Ref) } else { @('main', $FallbackRef) }
$fork = $null
foreach ($r in $candidates) {
    try {
        Write-Host "    trying $r..."
        $s = Get-RepoZip $Repo $r "fork-$($r -replace '[^\w.-]', '_')"
        if (Test-Path (Join-Path $s 'windows-service\patches\fork-changes.patch')) { $fork = $s; $usedRef = $r; break }
        Write-Host "    $r doesn't have the installer files yet."
    } catch {
        Write-Host "    couldn't fetch ${r}: $($_.Exception.Message)"
    }
}
if (-not $fork) { throw "Couldn't find a branch with windows-service\patches\fork-changes.patch (tried: $($candidates -join ', '))." }
Write-Host "    using $usedRef"

Say "Downloading official Tailscale $official source from github.com/$Upstream"
$officialSrc = Get-RepoZip $Upstream "refs/tags/v$official" 'official'
Write-Host "    got $(Split-Path $officialSrc -Leaf)"

Say 'Getting Git (only used to apply your changes)'
$gitExe = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
if ($gitExe) {
    Write-Host "    using installed $(& $gitExe --version)"
} else {
    $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -UseBasicParsing
    $pattern = if ($goArch -eq 'arm64') { '^MinGit-[\d.]+(\.windows\.\d+)?-arm64\.zip$' } else { '^MinGit-[\d.]+(\.windows\.\d+)?-64-bit\.zip$' }
    $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { throw "Couldn't find a portable Git (MinGit) download in $($rel.tag_name)." }
    Write-Host "    downloading $($asset.name)..."
    $gitZip = Join-Path $work $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $gitZip -UseBasicParsing
    if ("$($asset.digest)" -match '^sha256:([0-9a-f]{64})$') {
        $hash = (Get-FileHash $gitZip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $Matches[1]) { throw "Git download checksum mismatch ($hash, expected $($Matches[1]))." }
    }
    $gitDir = Join-Path $work 'mingit'
    Expand-Archive $gitZip $gitDir -Force
    $gitExe = Join-Path $gitDir 'cmd\git.exe'
}

Say "Laying your fork's changes on top of Tailscale $official"
$patch = Join-Path $fork 'windows-service\patches\fork-changes.patch'
$applyOut = Invoke-Quiet { & $gitExe -C $officialSrc apply --whitespace=nowarn $patch 2>&1 | Out-String }
if ($LASTEXITCODE -eq 0) {
    $buildSrc = $officialSrc
    $builtOn = $official
    Write-Host "    applied cleanly"
} else {
    # The official code moved under one of the changed files. Fall back to the
    # fork's own source (which tracks upstream main) rather than not updating.
    Write-Warning "Your changes don't apply cleanly to $official yet:`n$applyOut"
    Write-Warning "Building your fork's $usedRef branch as-is instead. Re-sync the fork with upstream to fix this."
    $buildSrc = $fork
    $builtOn = "$official (fork $usedRef)"
}

Say 'Getting Go'
$goExe = (Get-Command go.exe -ErrorAction SilentlyContinue).Source
if ($goExe) {
    Write-Host "    using installed $(& $goExe version)"
} else {
    $rel = (Invoke-RestMethod 'https://go.dev/dl/?mode=json' -UseBasicParsing) |
        Where-Object stable | Select-Object -First 1
    $file = $rel.files | Where-Object { $_.os -eq 'windows' -and $_.arch -eq $goArch -and $_.kind -eq 'archive' } |
        Select-Object -First 1
    if (-not $file) { throw "go.dev has no Windows $goArch archive for $($rel.version)." }
    Write-Host "    downloading $($file.filename) (about 75 MB)..."
    $goZip = Join-Path $work $file.filename
    Invoke-WebRequest "https://go.dev/dl/$($file.filename)" -OutFile $goZip -UseBasicParsing
    $hash = (Get-FileHash $goZip -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $file.sha256) { throw "Go download checksum mismatch ($hash, expected $($file.sha256))." }
    Expand-Zip $goZip (Join-Path $work 'go-dist')
    $goExe = Join-Path $work 'go-dist\go\bin\go.exe'
    Write-Host "    $(& $goExe version) (temporary, deleted when done)"
}

# --- 4. Build ------------------------------------------------------------------

Say 'Building tailscale.exe and tailscaled.exe (takes a few minutes)'
$out = Join-Path $work 'out'
New-Item -ItemType Directory $out | Out-Null
$env:GOOS = 'windows'
$env:GOARCH = $goArch
$env:CGO_ENABLED = '0'
$env:GOTOOLCHAIN = 'auto'          # fetches the exact Go version go.mod asks for, if newer
$env:GOPATH = Join-Path $work 'gopath'
$env:GOCACHE = Join-Path $work 'gocache'
$env:GOTELEMETRY = 'off'
Push-Location $buildSrc
try {
    foreach ($cmd in 'tailscale', 'tailscaled') {
        Write-Host "    go build ./cmd/$cmd"
        & $goExe build -trimpath -o (Join-Path $out "$cmd.exe") "./cmd/$cmd"
        if ($LASTEXITCODE -ne 0) { throw "Building $cmd failed (see the Go errors above). Nothing was changed." }
    }
} finally { Pop-Location }

$wolHelp = Invoke-Quiet { & (Join-Path $out 'tailscale.exe') wol --help 2>&1 | Out-String }
if ($wolHelp -notmatch 'tailscale wol \[--via') { throw "The build doesn't have 'tailscale wol'; stopping before anything is changed." }
Write-Host "    built $(Invoke-Quiet { & (Join-Path $out 'tailscale.exe') version 2>&1 | Select-Object -First 1 }); 'tailscale wol' is present"

# --- 5. Install ------------------------------------------------------------------

Say "Putting everything in $InstallDir"
New-Item -ItemType Directory $InstallDir -Force | Out-Null

# Updating an existing fork install: stop the service so the exes aren't locked.
$svc = Get-CimInstance Win32_Service -Filter "Name='Tailscale'" -ErrorAction SilentlyContinue
$forkSvc = $svc -and $svc.PathName -like "*$InstallDir*"
if ($forkSvc -and $svc.State -ne 'Stopped') {
    Write-Host "    stopping the running fork service to update it"
    Stop-Service Tailscale -Force
    (Get-Service Tailscale).WaitForStatus('Stopped', '00:00:30')
}

Copy-Item (Join-Path $out '*.exe') $InstallDir -Force
Copy-Item (Join-Path $fork 'windows-service\*.ps1') $InstallDir -Force
Copy-Item (Join-Path $fork 'windows-service\README.md') (Join-Path $InstallDir 'README.md') -Force
Copy-Item (Join-Path $fork 'windows-service\wintun') $InstallDir -Recurse -Force
Get-ChildItem $InstallDir -Recurse -File | Unblock-File
$ts = Join-Path $InstallDir 'tailscale.exe'

if ($Scheduled -and $forkSvc) {
    # Plain update: same service, same state, new files.
    Start-Service Tailscale
} else {
    Say 'Switching from the official app to your fork'
    $global:LASTEXITCODE = 0
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'Switch-ToFork.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Switch-ToFork.ps1 stopped (exit code $LASTEXITCODE). Its output above says where." }
}
Set-Content -Path $versionFile -Value $builtOn -Encoding ASCII

# --- 6. Keep the official updater from replacing the fork ------------------------

Say "Turning off Tailscale's built-in auto-update (it would install the stock build over your fork)"
Invoke-Quiet { & $ts set --auto-update=false 2>&1 | ForEach-Object { "    $_" } }

if (-not $NoUpdateTask -and -not $Scheduled) {
    Say "Scheduling '$TaskName' (daily check against pkgs.tailscale.com)"
    $script = Join-Path $InstallDir 'Install-TailscaleFork.ps1'
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Scheduled -InstallDir `"$InstallDir`" -Track $Track"
    if ($Ref) { $taskArgs += " -Ref `"$Ref`"" }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -Daily -At 4am
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
        -Principal $principal -Description "Rebuilds the Tailscale fork in $InstallDir on each new official Tailscale release." -Force | Out-Null
    Write-Host "    runs daily at 4 AM (or at next boot if missed); log: $InstallDir\update.log"
}

# --- 7. Wake-on-LAN and lag report (first install only) -------------------------

if (-not $Scheduled) {
    if (-not $SkipWakeOnLan) {
        Say 'Setting this PC up to be woken from sleep'
        $global:LASTEXITCODE = 0
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'Enable-WakeOnLan.ps1') -NoRestart
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Wake-on-LAN setup didn't finish (see above). Everything else is done; run $InstallDir\Enable-WakeOnLan.ps1 later, with Ethernet plugged in."
        } else {
            # Enable-WakeOnLan wrote TS_WAKE_MAC; restart once so it's advertised now.
            Restart-Service Tailscale -Force
        }
    }

    Say 'Checking for lag and other rough edges (report only; nothing changed here)'
    $global:LASTEXITCODE = 0
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'Tune-Tailscale.ps1') -ReportOnly
    if ($LASTEXITCODE -ne 0) { Write-Warning "Tune-Tailscale.ps1 didn't finish; run it by hand later from $InstallDir." }
}

# --- 8. Show the settings carried over ------------------------------------------

Say 'Checking your settings carried over'
$after = $null
for ($i = 0; $i -lt 15 -and -not $after; $i++) { $after = Get-TsPrefs $ts; if (-not $after) { Start-Sleep 2 } }
if ($before -and $after) {
    $changed = @()
    foreach ($k in $watched) {
        $b = ($before.$k | ConvertTo-Json -Compress)
        $a = ($after.$k | ConvertTo-Json -Compress)
        if ($b -ne $a) { $changed += "    $k`: $b -> $a" }
    }
    if ($changed) {
        Write-Warning "Some settings differ from before:"
        $changed | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    } else {
        Write-Host "    exit node, routes and the rest are exactly as before" -ForegroundColor Green
    }
    Show-Prefs $after
} elseif ($after) {
    Show-Prefs $after
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Your fork, built on Tailscale $builtOn, runs from $InstallDir as the 'Tailscale' service." -ForegroundColor Green
Invoke-Quiet { & $ts status 2>&1 | Select-Object -First 5 | ForEach-Object { "    $_" } }
if ($Scheduled) { try { Stop-Transcript | Out-Null } catch { } }
