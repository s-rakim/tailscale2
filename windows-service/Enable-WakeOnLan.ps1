#Requires -Version 5.1
<#
.SYNOPSIS
    Sets this PC up so other tailnet devices can wake it from sleep with
    "tailscale wol".

.DESCRIPTION
    A sleeping PC is off the tailnet, so nothing can reach it over Tailscale
    directly. What works is an awake device on the same LAN (a NAS, a Pi,
    another PC) sending it a Wake-on-LAN magic packet. "tailscale wol --via"
    already does that relay; this script does the part on the PC that sleeps:

      1. Turns on "wake on magic packet" for the wired network adapter(s), and
         turns off waking on other traffic so the PC doesn't wake randomly.
      2. Arms the adapter as a wake device (powercfg /deviceenablewake).
      3. Sets TS_WAKE_MAC in C:\ProgramData\Tailscale\tailscaled-env.txt so
         tailscaled tells the rest of the tailnet this PC's MAC address. That
         lets you wake it by name instead of typing the MAC.
      4. Restarts the Tailscale service if it's running, so the MAC is
         advertised right away (a few seconds' drop).

    Then, from any device in your tailnet:
        tailscale wol --via=<awake device on the same LAN> <this PC's name>

    Some things can't be set from Windows. On a Dell, enter the BIOS (F2 at
    boot) and set Power Management > Wake on LAN to "LAN Only", and Deep Sleep
    Control to "Disabled". Most laptops only wake over Ethernet, not Wi-Fi, and
    often only while plugged into power.

.PARAMETER Adapter
    Name of the adapter to use (as in Get-NetAdapter). Default: every physical
    wired adapter.

.PARAMETER IncludeWifi
    Also arm Wi-Fi adapters. Most laptops can't wake over Wi-Fi, but some can.

.PARAMETER Mac
    MAC to advertise, or "auto" to let tailscaled pick connected adapters.
    Default: the first wired adapter's MAC.

.PARAMETER FromShutdown
    Also allow waking from "Shut down", not just Sleep/Hibernate. This turns
    off Windows Fast Startup, which otherwise blocks it.

.PARAMETER NoRestart
    Don't restart the Tailscale service; the MAC is advertised on its next start.

.EXAMPLE
    .\Enable-WakeOnLan.ps1

.EXAMPLE
    # From another tailnet device, with "nas" awake on the laptop's LAN:
    tailscale wol --via=nas latitude
#>
[CmdletBinding()]
param(
    [string]$Adapter,
    [switch]$IncludeWifi,
    [string]$Mac,
    [switch]$FromShutdown,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Open PowerShell with 'Run as administrator' and run this again."
}

# --- pick adapters -------------------------------------------------------------

$all = Get-NetAdapter -Physical -ErrorAction SilentlyContinue
if ($Adapter) {
    $targets = @($all | Where-Object Name -eq $Adapter)
    if (-not $targets) { throw "No physical adapter named '$Adapter'. Run Get-NetAdapter -Physical to see the names." }
} else {
    $targets = @($all | Where-Object { ($_.PhysicalMediaType -eq '802.3' -or $_.MediaType -eq '802.3') -and $_.PhysicalMediaType -notmatch '802.11|Wireless' })
    if ($IncludeWifi) { $targets += @($all | Where-Object { $_.PhysicalMediaType -match '802.11|Wireless' }) }
}
if (-not $targets) {
    throw @"
No wired network adapter found. Wake-on-LAN almost always needs Ethernet
(a USB-C/Thunderbolt dock's Ethernet port counts if it's connected now).
Plug in Ethernet and run this again, or try -IncludeWifi.
"@
}

function Write-Done([string]$what) { Write-Host "    [ok] $what" -ForegroundColor Green }
function Write-Skip([string]$what) { Write-Host "    [--] $what" -ForegroundColor DarkYellow }

foreach ($a in $targets) {
    Write-Host ""
    Write-Host "$($a.Name): $($a.InterfaceDescription) ($($a.MacAddress), $($a.Status))" -ForegroundColor Cyan

    # Driver-level advanced properties. Names vary by vendor; set the ones present.
    $adv = Get-NetAdapterAdvancedProperty -Name $a.Name -AllProperties -ErrorAction SilentlyContinue
    $wanted = [ordered]@{
        '*WakeOnMagicPacket' = '1'   # standard keyword: wake on magic packet
        'EnablePME'          = '1'   # Intel: allow the NIC to wake the PC
        '*WakeOnPattern'     = '0'   # don't wake on ordinary traffic
    }
    if ($FromShutdown) { $wanted['S5WakeOnLan'] = '1' }   # Intel/Realtek: wake from power off
    foreach ($k in $wanted.Keys) {
        $p = $adv | Where-Object RegistryKeyword -eq $k | Select-Object -First 1
        if (-not $p) { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword $k -RegistryValue $wanted[$k] -NoRestart
            Write-Done "$($p.DisplayName) = $($wanted[$k])"
        } catch { Write-Skip "$($p.DisplayName): $($_.Exception.Message)" }
    }

    # Windows power-management tab ("Allow this device to wake the computer",
    # "Only allow a magic packet to wake the computer").
    try {
        Set-NetAdapterPowerManagement -Name $a.Name -WakeOnMagicPacket Enabled -WakeOnPattern Disabled -NoRestart
        Write-Done 'Power management: wake on magic packet only'
    } catch { Write-Skip "Power management: $($_.Exception.Message)" }

    $out = & powercfg.exe /deviceenablewake "$($a.InterfaceDescription)" 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Done 'Armed as a wake device' }
    else { Write-Skip "powercfg /deviceenablewake: $out" }
}

# --- Fast Startup ----------------------------------------------------------------

if ($FromShutdown) {
    Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -Value 0 -Type DWord
    Write-Host ""
    Write-Done 'Fast Startup turned off (needed to wake from Shut down)'
}

# --- advertise the MAC over Tailscale ------------------------------------------

if (-not $Mac) {
    $wired = $targets | Where-Object { $_.PhysicalMediaType -notmatch '802.11|Wireless' } | Select-Object -First 1
    if (-not $wired) { $wired = $targets | Select-Object -First 1 }
    $Mac = $wired.MacAddress
}
if ($Mac -ne 'auto') { $Mac = ($Mac -replace '-', ':').ToLower() }

$stateDir = Join-Path $env:ProgramData 'Tailscale'
New-Item -ItemType Directory $stateDir -Force | Out-Null
$envFile = Join-Path $stateDir 'tailscaled-env.txt'
$lines = @()
if (Test-Path $envFile) { $lines = @(Get-Content $envFile | Where-Object { $_ -notmatch '^\s*TS_WAKE_MAC\s*=' }) }
$lines += "TS_WAKE_MAC=$Mac"
Set-Content -Path $envFile -Value $lines -Encoding ASCII
Write-Host ""
Write-Done "TS_WAKE_MAC=$Mac written to $envFile"

$svc = Get-Service -Name Tailscale -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running' -and -not $NoRestart) {
    Write-Host "    restarting the Tailscale service to advertise it (a few seconds' drop)..."
    Restart-Service Tailscale -Force
    Write-Done 'Tailscale service restarted'
}

# --- report --------------------------------------------------------------------

Write-Host ""
Write-Host "Devices allowed to wake this PC:" -ForegroundColor Cyan
& powercfg.exe /devicequery wake_armed | ForEach-Object { "    $_" }

$available = ((& powercfg.exe /a) -join "`n") -split 'not available', 2 | Select-Object -First 1
if ($available -match 'S0 Low Power Idle') {
    Write-Host ""
    Write-Host "Note: this PC uses Modern Standby. Wake-on-LAN from Modern Standby depends on" -ForegroundColor Yellow
    Write-Host "the network driver; if it doesn't wake, test with Hibernate as well." -ForegroundColor Yellow
}

$name = $env:COMPUTERNAME.ToLower()
Write-Host ""
Write-Host "Done. Still to do on the hardware side:" -ForegroundColor Green
Write-Host "  - BIOS (F2 at boot on a Dell): Wake on LAN = 'LAN Only', Deep Sleep Control = Disabled."
Write-Host "  - Leave Ethernet plugged in, and the charger, when it sleeps."
Write-Host ""
Write-Host "To wake it, from any tailnet device, through an awake device on the same LAN:"
Write-Host "    tailscale wol --via=<awake-device> $name"
