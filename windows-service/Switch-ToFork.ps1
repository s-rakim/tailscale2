#Requires -Version 5.1
<#
.SYNOPSIS
    One command to swap the official Tailscale app for your fork, keeping your
    login.

.DESCRIPTION
    Runs the three setup scripts in order, from the folder this script is in:
      1. Remove-OfficialTailscale.ps1  - uninstalls the official app and tray
                                         GUI, keeps C:\ProgramData\Tailscale
      2. Install-TailscaleService.ps1  - puts wintun.dll in place, registers
                                         and starts the fork's tailscaled
      3. Logs in: if the saved login came through, it just switches on
         Unattended Mode; otherwise it runs Connect-Tailscale.ps1, which opens
         the login page in your browser.

    Put this folder somewhere permanent first (e.g. C:\Tailscale). The script
    refuses to run from inside C:\Program Files\Tailscale, because the
    uninstaller deletes that folder.

.PARAMETER Hostname
    Passed to Connect-Tailscale.ps1 if a fresh login is needed.

.PARAMETER PromptForAuthKey
    If a fresh login is needed, paste an auth key instead of using the browser.

.EXAMPLE
    cd C:\Tailscale
    .\Switch-ToFork.ps1
#>
[CmdletBinding()]
param(
    [string]$Hostname,
    [switch]$PromptForAuthKey
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Run this from PowerShell opened with 'Run as administrator'."
    exit 1
}

$here = $PSScriptRoot
$officialDir = Join-Path $env:ProgramFiles 'Tailscale'
if ($here.TrimEnd('\') -like "$officialDir*") {
    Write-Error @"
This folder is inside $officialDir, which the official uninstaller deletes.
Copy the whole folder to C:\Tailscale and run it from there.
"@
    exit 1
}

# Everything we need has to be here before we remove anything.
$needed = @(
    'tailscaled.exe', 'tailscale.exe',
    'Remove-OfficialTailscale.ps1', 'Install-TailscaleService.ps1', 'Connect-Tailscale.ps1'
)
$missing = $needed | Where-Object { -not (Test-Path (Join-Path $here $_)) }
if (-not (Test-Path (Join-Path $here 'wintun.dll')) -and
    -not (Test-Path (Join-Path $here 'wintun\amd64\wintun.dll')) -and
    -not (Test-Path (Join-Path $here 'wintun\arm64\wintun.dll'))) {
    $missing += 'wintun\<arch>\wintun.dll'
}
if ($missing) {
    Write-Error "Missing from ${here}: $($missing -join ', '). Nothing was changed."
    exit 1
}

Get-ChildItem $here -Recurse -File | Unblock-File

function Invoke-Step([string]$Title, [scriptblock]$Body) {
    Write-Host ""
    Write-Host "=== $Title" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    try { & $Body } catch {
        Write-Host $_ -ForegroundColor Red
        Write-Error "Stopped at: $Title"
        exit 1
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Stopped at: $Title (exit code $LASTEXITCODE)"
        exit 1
    }
}

Invoke-Step 'Removing the official Tailscale app' {
    & (Join-Path $here 'Remove-OfficialTailscale.ps1')
}

# If our own service from an earlier run is still registered, the installer
# would refuse; it already points at this folder, so just make sure it runs.
$existing = Get-CimInstance Win32_Service -Filter "Name='Tailscale'" -ErrorAction SilentlyContinue
if ($existing -and $existing.PathName -like "*$here*") {
    Invoke-Step 'Starting the existing fork service' {
        Set-Service Tailscale -StartupType Automatic
        if ((Get-Service Tailscale).Status -ne 'Running') { Start-Service Tailscale }
    }
} else {
    Invoke-Step "Installing the fork's service" {
        & (Join-Path $here 'Install-TailscaleService.ps1') -BinaryPath (Join-Path $here 'tailscaled.exe')
    }
}

# Wait for tailscaled to load its state and report where it stands.
$ts = Join-Path $here 'tailscale.exe'
$state = $null
Write-Host ""
Write-Host "Waiting for tailscaled to start..."
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $json = & $ts status --json 2>$null | Out-String
        if ($json) { $state = ($json | ConvertFrom-Json).BackendState }
    } catch { }
    if ($state -and $state -notin 'NoState', 'Starting') { break }
}
Write-Host "tailscaled says: $state"

if ($state -eq 'Running' -or $state -eq 'Stopped') {
    Invoke-Step 'Keeping your existing login' {
        # Make the saved login belong to the machine, not your Windows user,
        # so it stays up at the lock screen and after you sign out.
        & $ts set --unattended
        # Plain "up" with no flags just reconnects using the saved settings.
        if ($LASTEXITCODE -eq 0 -and $state -eq 'Stopped') { & $ts up }
    }
} else {
    Invoke-Step 'Logging in' {
        $connectArgs = @{}
        if ($Hostname) { $connectArgs.Hostname = $Hostname }
        if ($PromptForAuthKey) { $connectArgs.PromptForAuthKey = $true }
        & (Join-Path $here 'Connect-Tailscale.ps1') @connectArgs
    }
}

Write-Host ""
Write-Host "All done. Your fork is running as the 'Tailscale' service." -ForegroundColor Green
& $ts status
