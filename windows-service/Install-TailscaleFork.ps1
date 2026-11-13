#Requires -Version 5.1
<#
.SYNOPSIS
    Fully automatic switch from the official Tailscale app to your fork. Nothing
    to download or copy by hand.

.DESCRIPTION
    Run it once from an Administrator PowerShell. It:
      1. Records your current settings (exit node, advertised routes, Wake-on-LAN
         config) so it can prove afterwards that nothing changed.
      2. Downloads your fork's source from GitHub and a Go toolchain from go.dev
         (into a temp folder, checksum-verified; your system is left alone).
      3. Builds tailscale.exe and tailscaled.exe into C:\Tailscale (Wake-on-LAN,
         including "tailscale wol", is built in), and puts the setup scripts and
         the signed wintun.dll next to them.
      4. Runs Switch-ToFork.ps1: removes the official app and tray GUI, installs
         the fork as the auto-start "Tailscale" service, and keeps your login.
      5. Arms the wired network adapter for Wake-on-LAN and advertises this PC's
         MAC over the tailnet, so "tailscale wol --via=<device> <this pc>" can
         wake it from sleep (skip with -SkipWakeOnLan).
      6. Runs Tune-Tailscale.ps1 -ReportOnly, which measures where any internet
         lag comes from (relayed exit node, DNS, LAN access, overlapping routes)
         and prints the fixes. Run Tune-Tailscale.ps1 afterwards to apply the
         safe ones.
      7. Compares your settings before and after and prints the result.

    It never changes your exit node or routes. Your login and settings live in
    C:\ProgramData\Tailscale, which carries over; the only setting it switches
    on is Unattended Mode, so the connection belongs to the machine rather than
    your Windows account. It doesn't touch your network card's own Wake-on-LAN
    settings, and TS_WAKE_MAC in C:\ProgramData\Tailscale\tailscaled-env.txt (or
    a system environment variable) carries over as-is.

    Re-running it later rebuilds from the latest code and updates in place.

.PARAMETER InstallDir
    Where the fork lives. Default C:\Tailscale.

.PARAMETER SkipWakeOnLan
    Don't run Enable-WakeOnLan.ps1 (which arms the wired adapter so other
    tailnet devices can wake this PC from sleep, and advertises its MAC).

.PARAMETER Ref
    Git branch or tag to build. Default: main, falling back to the
    windows-bundled-wintun branch while that PR is still open.

.EXAMPLE
    # One line in an Administrator PowerShell, nothing to download first:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/s-rakim/tailscale2/windows-bundled-wintun/windows-service/Install-TailscaleFork.ps1)))
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Tailscale',
    [string]$Ref,
    [switch]$SkipWakeOnLan
)

# This script is often run as a script block via irm, where "exit" would close
# the whole PowerShell window. So it uses throw for errors instead.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is far faster without the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Repo = 's-rakim/tailscale2'
$FallbackRef = 'windows-bundled-wintun'

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

# --- 1. Snapshot the settings we promise not to touch -------------------------

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
    (Join-Path $officialDir 'tailscale.exe'),
    (Join-Path $InstallDir 'tailscale.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
$before = Get-TsPrefs $currentExe
if ($before) {
    Show-Prefs $before
} else {
    Write-Host "    (couldn't read settings; the service may not be running. Carrying on.)"
}

$envFile = Join-Path $env:ProgramData 'Tailscale\tailscaled-env.txt'
$wakeMac = [Environment]::GetEnvironmentVariable('TS_WAKE_MAC', 'Machine')
if (Test-Path $envFile) {
    $line = Select-String -Path $envFile -Pattern '^\s*TS_WAKE_MAC\s*=' | Select-Object -First 1
    if ($line) { $wakeMac = ($line.Line -split '=', 2)[1].Trim() }
}
if ($wakeMac) { Write-Host "    TS_WAKE_MAC              $wakeMac (carries over)" }

# --- 2. Download source and Go -------------------------------------------------

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

function Get-Source([string]$R) {
    $zip = Join-Path $work "src-$($R -replace '[^\w.-]', '_').zip"
    Invoke-WebRequest "https://codeload.github.com/$Repo/zip/$R" -OutFile $zip -UseBasicParsing
    $dest = Join-Path $work "src-$($R -replace '[^\w.-]', '_')"
    Expand-Zip $zip $dest
    return (Get-ChildItem $dest -Directory | Select-Object -First 1).FullName
}

Say "Downloading your fork's source from github.com/$Repo"
$candidates = if ($Ref) { @($Ref) } else { @('main', $FallbackRef) }
$src = $null
foreach ($r in $candidates) {
    try {
        Write-Host "    trying $r..."
        $s = Get-Source $r
        if (Test-Path (Join-Path $s 'windows-service\Switch-ToFork.ps1')) { $src = $s; $usedRef = $r; break }
        Write-Host "    $r doesn't have the Windows service scripts yet."
    } catch {
        Write-Host "    couldn't fetch ${r}: $($_.Exception.Message)"
    }
}
if (-not $src) { throw "Couldn't find a branch with windows-service\Switch-ToFork.ps1 (tried: $($candidates -join ', '))." }
Write-Host "    using $usedRef"

Say 'Getting Go'
$goExe = $null
$sysGo = Get-Command go.exe -ErrorAction SilentlyContinue
if ($sysGo) {
    $goExe = $sysGo.Source
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

# --- 3. Build ------------------------------------------------------------------

Say 'Building tailscale.exe and tailscaled.exe (first build takes a few minutes)'
$out = Join-Path $work 'out'
New-Item -ItemType Directory $out | Out-Null
$env:GOOS = 'windows'
$env:GOARCH = $goArch
$env:CGO_ENABLED = '0'
$env:GOTOOLCHAIN = 'auto'          # fetches the exact Go version go.mod asks for, if newer
$env:GOPATH = Join-Path $work 'gopath'
$env:GOCACHE = Join-Path $work 'gocache'
$env:GOTELEMETRY = 'off'
Push-Location $src
try {
    foreach ($cmd in 'tailscale', 'tailscaled') {
        Write-Host "    go build ./cmd/$cmd"
        & $goExe build -trimpath -o (Join-Path $out "$cmd.exe") "./cmd/$cmd"
        if ($LASTEXITCODE -ne 0) { throw "Building $cmd failed (see the Go errors above)." }
    }
} finally { Pop-Location }

$wolHelp = Invoke-Quiet { & (Join-Path $out 'tailscale.exe') wol --help 2>&1 | Out-String }
if ($wolHelp -notmatch 'tailscale wol \[--via') { throw "The build doesn't have 'tailscale wol'; stopping before anything is changed." }
Write-Host "    built; 'tailscale wol' is present"

# --- 4. Lay out C:\Tailscale and switch --------------------------------------

Say "Putting everything in $InstallDir"
New-Item -ItemType Directory $InstallDir -Force | Out-Null

# Updating an existing fork install: stop the service so the exes aren't locked.
$svc = Get-CimInstance Win32_Service -Filter "Name='Tailscale'" -ErrorAction SilentlyContinue
if ($svc -and $svc.PathName -like "*$InstallDir*" -and $svc.State -ne 'Stopped') {
    Write-Host "    stopping the running fork service to update it"
    Stop-Service Tailscale -Force
    (Get-Service Tailscale).WaitForStatus('Stopped', '00:00:30')
}

Copy-Item (Join-Path $out '*.exe') $InstallDir -Force
Copy-Item (Join-Path $src 'windows-service\*.ps1') $InstallDir -Force
Copy-Item (Join-Path $src 'windows-service\README.md') (Join-Path $InstallDir 'README.md') -Force
Copy-Item (Join-Path $src 'windows-service\wintun') $InstallDir -Recurse -Force
Get-ChildItem $InstallDir -Recurse -File | Unblock-File

Say 'Switching from the official app to your fork'
$global:LASTEXITCODE = 0
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'Switch-ToFork.ps1')
if ($LASTEXITCODE -ne 0) { throw "Switch-ToFork.ps1 stopped (exit code $LASTEXITCODE). Its output above says where." }

# --- 5. Let the rest of the tailnet wake this PC -------------------------------

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

# --- 6. Check for anything slowing the internet down --------------------------

Say 'Checking for lag and other rough edges (report only; nothing changed here)'
$global:LASTEXITCODE = 0
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'Tune-Tailscale.ps1') -ReportOnly
if ($LASTEXITCODE -ne 0) { Write-Warning "Tune-Tailscale.ps1 didn't finish; run it by hand later from $InstallDir." }

# --- 7. Prove the settings carried over ----------------------------------------

Say 'Checking your settings carried over'
$after = Get-TsPrefs (Join-Path $InstallDir 'tailscale.exe')
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
        Write-Host "Nothing was changed on purpose; tell me and I'll help put them back."
    } else {
        Write-Host "    exit node, routes and the rest are exactly as before" -ForegroundColor Green
    }
    Show-Prefs $after
} elseif ($after) {
    Show-Prefs $after
}
Write-Host ""
Invoke-Quiet { & (Join-Path $InstallDir 'tailscale.exe') wol --help 2>&1 | Select-Object -First 3 | ForEach-Object { "$_" } }

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Done. Your fork runs from $InstallDir as the 'Tailscale' service and starts at boot." -ForegroundColor Green
Write-Host "To apply the safe lag fixes listed above:  $InstallDir\Tune-Tailscale.ps1"
Write-Host "To update later, run this same command again."
