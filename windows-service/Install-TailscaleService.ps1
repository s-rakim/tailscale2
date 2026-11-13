#Requires -Version 5.1
<#
.SYNOPSIS
    Installs tailscaled as a Windows service that starts automatically at boot
    and runs quietly in the background.

.DESCRIPTION
    Registers your forked tailscaled.exe as a Windows service set to start
    automatically, so Tailscale comes up on boot without anyone logging in and
    without a console window. A Windows service has no UI of its own, so there is
    no window, tray popup, or console to dismiss once this is done.

    By default the script uses tailscaled's own built-in installer
    (`tailscaled install-system-daemon`), which is the same code path the
    official build uses: it creates the service with automatic start, the right
    service dependencies, and crash-recovery/restart actions. If that command
    isn't available on the binary you point it at, the script falls back to
    creating an equivalent service with New-Service.

    This is an ordinary, visible Windows service. It shows up in services.msc and
    Task Manager like any other service. It does nothing to hide itself and is not
    meant to.

.PARAMETER BinaryPath
    Full path to tailscaled.exe. Defaults to a tailscaled.exe sitting next to this
    script, then C:\Program Files\Tailscale\tailscaled.exe.

.PARAMETER ServiceName
    Service name to register. Defaults to "Tailscale" (what the official app uses).
    If the official Tailscale app is already installed, that name is taken; pass
    something like -ServiceName TailscaleFork to run yours alongside it.

.PARAMETER Start
    Start the service immediately after installing. Default: $true.

.EXAMPLE
    # From an elevated PowerShell, with tailscaled.exe next to the script:
    .\Install-TailscaleService.ps1

.EXAMPLE
    .\Install-TailscaleService.ps1 -BinaryPath 'C:\Tailscale\tailscaled.exe' -ServiceName TailscaleFork

.NOTES
    Run from an elevated (Administrator) PowerShell. The script stops and tells you
    how if it isn't elevated.
#>
[CmdletBinding()]
param(
    [string]$BinaryPath,
    [string]$ServiceName = 'Tailscale',
    [bool]$Start = $true
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Error @"
This script needs Administrator rights to create a Windows service.

Open PowerShell as Administrator (Start -> type 'powershell' -> right-click
'Windows PowerShell' -> 'Run as administrator'), then run it again.
"@
    exit 1
}

# Resolve tailscaled.exe.
if (-not $BinaryPath) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'tailscaled.exe'),
        'C:\Program Files\Tailscale\tailscaled.exe'
    )
    $BinaryPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $BinaryPath -or -not (Test-Path $BinaryPath)) {
    Write-Error @"
Could not find tailscaled.exe.

Pass its full path, e.g.:
    .\Install-TailscaleService.ps1 -BinaryPath 'C:\path\to\tailscaled.exe'
"@
    exit 1
}

$BinaryPath = (Resolve-Path $BinaryPath).Path
Write-Host "Using tailscaled: $BinaryPath"

# tailscaled needs wintun.dll for its network adapter, and only looks next to
# the exe and in System32 (see cmd/tailscaled/tailscaled_windows.go). The repo
# ships a signed copy in .\wintun\<arch>\, so copy that in when it's missing.
# The hashes match wintun 0.14.1 from wintun.net (see wintun\README.md).
$WintunHashes = @{
    'amd64' = 'E5DA8447DC2C320EDC0FC52FA01885C103DE8C118481F683643CACC3220DAFCE'
    'arm64' = 'F7BA89005544BE9D85231A9E0D5F23B2D15B3311667E2DAD0DEBD344918A3F80'
}

function Get-PEArch([string]$Path) {
    # Read the COFF Machine field so we match the DLL to the exe, not to the OS
    # (an amd64 tailscaled on an ARM PC still needs the amd64 wintun.dll).
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $fs.Position = $br.ReadInt32() + 4
        switch ($br.ReadUInt16()) {
            0x8664 { return 'amd64' }
            0xAA64 { return 'arm64' }
            default { return $null }
        }
    } finally { $fs.Dispose() }
}

function Test-Wintun([string]$Path, [string]$Arch) {
    $hash = (Get-FileHash -Algorithm SHA256 $Path).Hash
    if ($hash -ne $WintunHashes[$Arch]) {
        Write-Warning "$Path has SHA-256 $hash, expected $($WintunHashes[$Arch]) for $Arch."
        return $false
    }
    $sig = Get-AuthenticodeSignature $Path
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'WireGuard LLC') {
        Write-Warning "$Path is not validly signed by WireGuard LLC (status: $($sig.Status))."
        return $false
    }
    return $true
}

$exeDir = Split-Path $BinaryPath
$wintunNextToExe = Join-Path $exeDir 'wintun.dll'
$wintunSystem32 = Join-Path $env:SystemRoot 'System32\wintun.dll'

if (Test-Path $wintunNextToExe) {
    Write-Host "Found wintun.dll next to tailscaled.exe."
} else {
    $arch = Get-PEArch $BinaryPath
    if (-not $arch) {
        Write-Error "Couldn't tell what CPU architecture $BinaryPath was built for. Expected amd64 or arm64."
        exit 1
    }
    $bundled = @(
        (Join-Path $PSScriptRoot "wintun\$arch\wintun.dll"),
        (Join-Path $PSScriptRoot 'wintun.dll')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($bundled -and (Test-Wintun $bundled $arch)) {
        Copy-Item $bundled $wintunNextToExe
        $license = Join-Path $PSScriptRoot 'wintun\LICENSE.txt'
        if (Test-Path $license) { Copy-Item $license (Join-Path $exeDir 'wintun-LICENSE.txt') -Force }
        Write-Host "Copied bundled $arch wintun.dll to $wintunNextToExe"
    } elseif (Test-Path $wintunSystem32) {
        Write-Host "Using wintun.dll from System32."
    } else {
        Write-Error @"
No usable wintun.dll for $arch.

tailscaled can't create its network adapter without it. The repo ships one at
windows-service\wintun\$arch\wintun.dll; keep the 'wintun' folder next to this
script, or put wintun.dll from
https://www.wintun.net/builds/wintun-0.14.1.zip (wintun\bin\$arch\wintun.dll)
here:
    $wintunNextToExe
"@
        exit 1
    }
}

# Bail out early if the service already exists.
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Error @"
A service named '$ServiceName' already exists.

If that's the official Tailscale app, either leave it as-is, or run this script
with a different name, e.g. -ServiceName TailscaleFork. To remove an install made
by this script, use Uninstall-TailscaleService.ps1.
"@
    exit 1
}

$usedNativeInstaller = $false

# Preferred path: let tailscaled install itself. This sets automatic start,
# service dependencies, and restart-on-crash recovery actions for us.
if ($ServiceName -eq 'Tailscale') {
    Write-Host "Installing via 'tailscaled install-system-daemon'..."
    & $BinaryPath install-system-daemon
    if ($LASTEXITCODE -eq 0) {
        $usedNativeInstaller = $true
    } else {
        Write-Warning "tailscaled install-system-daemon exited with code $LASTEXITCODE; falling back to New-Service."
    }
}

# Fallback (or custom service name): create an equivalent service directly.
if (-not $usedNativeInstaller) {
    Write-Host "Creating service '$ServiceName' with New-Service..."
    New-Service `
        -Name $ServiceName `
        -BinaryPathName "`"$BinaryPath`"" `
        -DisplayName $ServiceName `
        -Description 'Connects this computer to others on the Tailscale network.' `
        -StartupType Automatic | Out-Null

    # Restart the service automatically if it crashes (1s, then 2s, then every 5s;
    # reset the failure counter after a day).
    & sc.exe failure $ServiceName reset= 86400 actions= restart/1000/restart/2000/restart/5000 | Out-Null
}

# Make doubly sure start type is Automatic regardless of which path we took.
Set-Service -Name $ServiceName -StartupType Automatic

if ($Start) {
    Write-Host "Starting '$ServiceName'..."
    Start-Service -Name $ServiceName
}

$svc = Get-Service -Name $ServiceName
Write-Host ""
Write-Host "Done. Service '$($svc.Name)' is $($svc.Status), StartType=$((Get-Service -Name $ServiceName).StartType)." -ForegroundColor Green
Write-Host "It will now start automatically on every boot, in the background, with no window."
Write-Host ""
Write-Host "Next, log in once:"
Write-Host "    .\Connect-Tailscale.ps1"
Write-Host "After that it reconnects on its own at boot."
