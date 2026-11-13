#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls the official Tailscale app (the tray GUI and its service) so the
    fork can take over, while keeping your login state.

.DESCRIPTION
    Does the following, in order:
      1. Closes the tray app (tailscale-ipn.exe).
      2. Backs up C:\ProgramData\Tailscale, where your node key and login live,
         to C:\ProgramData\Tailscale.backup-<timestamp>.
      3. Runs the official app's own uninstaller silently.
      4. Deletes the "Tailscale" service if the uninstaller left it behind
         pointing at C:\Program Files\Tailscale.
      5. Puts the state folder back if the uninstaller removed it.

    It never touches your fork's folder (e.g. C:\Tailscale). Run
    Install-TailscaleService.ps1 afterwards to set up the fork's service.

.PARAMETER KeepState
    Restore C:\ProgramData\Tailscale after uninstalling. Default: $true. Set it
    to $false to start completely fresh (you'll log in again).

.EXAMPLE
    .\Remove-OfficialTailscale.ps1
    .\Install-TailscaleService.ps1
    .\Connect-Tailscale.ps1

.NOTES
    Run from an elevated (Administrator) PowerShell. If you're connected to
    this PC over Tailscale (RDP/SSH), you will drop off until the fork's service
    is installed and running.
#>
[CmdletBinding()]
param(
    [bool]$KeepState = $true
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run this from PowerShell opened with 'Run as administrator'."
    exit 1
}

$stateDir = Join-Path $env:ProgramData 'Tailscale'
$officialDir = Join-Path $env:ProgramFiles 'Tailscale'

# Find the official app's uninstall entry (64-bit and 32-bit views).
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$entries = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like 'Tailscale*' -and $_.Publisher -like 'Tailscale*' }

if (-not $entries) {
    Write-Host "The official Tailscale app isn't installed. Nothing to remove." -ForegroundColor Green
    exit 0
}

foreach ($e in $entries) { Write-Host "Found: $($e.DisplayName) $($e.DisplayVersion)" }

# 1. Close the tray app.
Get-Process -Name 'tailscale-ipn' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Closing the tray app (pid $($_.Id))..."
    $_ | Stop-Process -Force
}

# 2. Back up login state.
$backup = $null
if (Test-Path $stateDir) {
    $svc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Host "Stopping the Tailscale service so the state files are consistent..."
        Stop-Service 'Tailscale' -Force
        $svc.WaitForStatus('Stopped', '00:00:30')
    }
    $backup = "$stateDir.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "Backing up $stateDir to $backup"
    Copy-Item $stateDir $backup -Recurse
}

# 3. Run the official uninstaller silently.
foreach ($e in $entries) {
    $code = $e.PSChildName
    if ($code -match '^\{[0-9A-Fa-f-]{36}\}$') {
        Write-Host "Uninstalling $($e.DisplayName) (MSI $code)..."
        $p = Start-Process msiexec.exe -ArgumentList "/x $code /qn /norestart" -Wait -PassThru
    } elseif ($e.QuietUninstallString) {
        Write-Host "Uninstalling $($e.DisplayName)..."
        $p = Start-Process cmd.exe -ArgumentList "/c $($e.QuietUninstallString)" -Wait -PassThru
    } elseif ($e.UninstallString) {
        Write-Host "Uninstalling $($e.DisplayName) (its uninstaller may show a window)..."
        $p = Start-Process cmd.exe -ArgumentList "/c $($e.UninstallString)" -Wait -PassThru
    } else {
        Write-Warning "No uninstall command for $($e.DisplayName); remove it from Settings > Apps."
        continue
    }
    # 0 = done, 3010 = done but wants a reboot, 1605 = already gone.
    if ($p.ExitCode -notin 0, 3010, 1605) {
        Write-Error "Uninstaller exited with code $($p.ExitCode). Try Settings > Apps > Tailscale > Uninstall."
        exit 1
    }
    if ($p.ExitCode -eq 3010) { Write-Warning "Windows wants a reboot to finish the uninstall." }
}

# 4. Clean up a leftover service that still points at the old install.
$svc = Get-CimInstance Win32_Service -Filter "Name='Tailscale'" -ErrorAction SilentlyContinue
if ($svc -and $svc.PathName -like "*$officialDir*") {
    Write-Host "Removing leftover 'Tailscale' service..."
    Stop-Service 'Tailscale' -Force -ErrorAction SilentlyContinue
    & sc.exe delete Tailscale | Out-Null
}

# 5. Keep the login.
if ($KeepState -and $backup -and -not (Test-Path $stateDir)) {
    Write-Host "Restoring your login state to $stateDir"
    Copy-Item $backup $stateDir -Recurse
}

Write-Host ""
Write-Host "Official Tailscale app removed." -ForegroundColor Green
if ($backup) { Write-Host "Backup of your state: $backup (delete it once the fork is working)." }
Write-Host "Next:"
Write-Host "    .\Install-TailscaleService.ps1"
Write-Host "    .\Connect-Tailscale.ps1"
