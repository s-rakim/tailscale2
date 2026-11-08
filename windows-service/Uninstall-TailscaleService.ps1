#Requires -Version 5.1
<#
.SYNOPSIS
    Stops and removes the tailscaled Windows service created by
    Install-TailscaleService.ps1.

.DESCRIPTION
    Stops the service if it's running, then deletes it. By default it uses
    tailscaled's own `uninstall-system-daemon` when removing the standard
    "Tailscale" service; otherwise it removes the service directly.

    This only removes the service registration. It does not delete tailscaled.exe
    or your Tailscale state in C:\ProgramData\Tailscale, so you can reinstall the
    service later and still be logged in.

.PARAMETER ServiceName
    Service name to remove. Defaults to "Tailscale". Use the same name you passed
    to Install-TailscaleService.ps1.

.PARAMETER BinaryPath
    Optional path to tailscaled.exe, used for the native uninstall path. Defaults
    to one next to this script, then C:\Program Files\Tailscale\tailscaled.exe.

.EXAMPLE
    .\Uninstall-TailscaleService.ps1

.EXAMPLE
    .\Uninstall-TailscaleService.ps1 -ServiceName TailscaleFork

.NOTES
    Run from an elevated (Administrator) PowerShell.
#>
[CmdletBinding()]
param(
    [string]$ServiceName = 'Tailscale',
    [string]$BinaryPath
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Error @"
This script needs Administrator rights to remove a Windows service.

Open PowerShell as Administrator and run it again.
"@
    exit 1
}

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Host "No service named '$ServiceName' found; nothing to do."
    exit 0
}

# Stop it first so delete succeeds cleanly.
if ($svc.Status -ne 'Stopped') {
    Write-Host "Stopping '$ServiceName'..."
    Stop-Service -Name $ServiceName -Force
    (Get-Service -Name $ServiceName).WaitForStatus('Stopped', '00:00:30')
}

$removed = $false

# Preferred path for the standard service: let tailscaled uninstall itself.
if ($ServiceName -eq 'Tailscale') {
    if (-not $BinaryPath) {
        $candidates = @(
            (Join-Path $PSScriptRoot 'tailscaled.exe'),
            'C:\Program Files\Tailscale\tailscaled.exe'
        )
        $BinaryPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if ($BinaryPath -and (Test-Path $BinaryPath)) {
        Write-Host "Removing via 'tailscaled uninstall-system-daemon'..."
        & $BinaryPath uninstall-system-daemon
        if ($LASTEXITCODE -eq 0) { $removed = $true }
        else { Write-Warning "uninstall-system-daemon exited with code $LASTEXITCODE; removing service directly." }
    }
}

if (-not $removed) {
    Write-Host "Removing service '$ServiceName'..."
    # Remove-Service exists in PowerShell 6+; sc.exe works everywhere, incl. Win PS 5.1.
    if (Get-Command Remove-Service -ErrorAction SilentlyContinue) {
        Remove-Service -Name $ServiceName
    } else {
        & sc.exe delete $ServiceName | Out-Null
    }
}

Write-Host ""
Write-Host "Done. Service '$ServiceName' removed." -ForegroundColor Green
Write-Host "tailscaled.exe and your login state were left in place."
