#Requires -Version 5.1
<#
.SYNOPSIS
    Logs this machine in to your tailnet without the Tailscale GUI.

.DESCRIPTION
    Runs `tailscale up` against the tailscaled service and, when Tailscale
    hands back a login link, opens it in your default browser. Once you finish
    signing in there, the script prints the connection status and exits.

    By default it uses Unattended Mode (`--unattended`), so the connection
    belongs to the machine rather than to whoever happens to be logged in to
    Windows. That's what you want with no GUI: the tunnel stays up at the login
    screen, after you sign out, and after a reboot.

    For a headless box you can skip the browser entirely with an auth key from
    the admin console (Settings > Keys). Pass it with -AuthKey, or set the
    TS_AUTHKEY environment variable, or use -PromptForAuthKey to type it in
    without it landing in your PowerShell history.

    Settings you don't pass are left exactly as they are (your exit node,
    routes and so on), unless you add -Reset.

.PARAMETER TailscaleExe
    Path to tailscale.exe. Defaults to one next to this script, then one next to
    the running service's tailscaled.exe, then whatever is on PATH.

.PARAMETER AuthKey
    Pre-authorized key (tskey-auth-...). Optional. Falls back to $env:TS_AUTHKEY.

.PARAMETER PromptForAuthKey
    Ask for the auth key interactively instead of passing it on the command line.

.PARAMETER Hostname
    Name this machine shows up as in the tailnet. Defaults to the Windows name.

.PARAMETER LoginServer
    Control server URL. Only set this for a self-hosted control server such as
    Headscale; leave it out for the normal Tailscale service.

.PARAMETER AcceptRoutes
    Accept subnet routes advertised by other nodes.

.PARAMETER ExitNode
    Route all internet traffic through this tailnet node (name or IP).

.PARAMETER AdvertiseExitNode
    Offer this machine as an exit node for the rest of the tailnet.

.PARAMETER NoUnattended
    Tie the connection to the current Windows user instead of the machine.

.PARAMETER Reset
    Reset any setting you don't pass back to its default.

.PARAMETER ForceReauth
    Log in again even if this machine is already logged in. Don't do this over
    RDP or SSH that runs through Tailscale; you'll cut yourself off.

.PARAMETER NoBrowser
    Print the login link instead of opening it.

.EXAMPLE
    .\Connect-Tailscale.ps1
    Opens the login page in your browser, then shows status once you're in.

.EXAMPLE
    .\Connect-Tailscale.ps1 -PromptForAuthKey -Hostname latitude
    Logs in with an auth key you paste in, no browser needed.

.EXAMPLE
    .\Connect-Tailscale.ps1 -AcceptRoutes -ExitNode nas
#>
[CmdletBinding()]
param(
    [string]$TailscaleExe,
    [string]$AuthKey,
    [switch]$PromptForAuthKey,
    [string]$Hostname,
    [string]$LoginServer,
    [switch]$AcceptRoutes,
    [string]$ExitNode,
    [switch]$AdvertiseExitNode,
    [switch]$NoUnattended,
    [switch]$Reset,
    [switch]$ForceReauth,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Find tailscale.exe.
if (-not $TailscaleExe) {
    $candidates = @((Join-Path $PSScriptRoot 'tailscale.exe'))
    $svc = Get-CimInstance Win32_Service -Filter "Name LIKE 'Tailscale%'" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($svc -and $svc.PathName) {
        $daemon = $svc.PathName.Trim().Split('"', [StringSplitOptions]::RemoveEmptyEntries)[0].Trim()
        $candidates += Join-Path (Split-Path $daemon) 'tailscale.exe'
    }
    $onPath = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($onPath) { $candidates += $onPath.Source }
    $TailscaleExe = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $TailscaleExe -or -not (Test-Path $TailscaleExe)) {
    Write-Error "Couldn't find tailscale.exe. Pass it with -TailscaleExe 'C:\Tailscale\tailscale.exe'."
    exit 1
}
Write-Host "Using $TailscaleExe"

# Make sure the daemon is actually running before we talk to it.
$svc = Get-Service -Name 'Tailscale*' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $svc) {
    Write-Error "No Tailscale service is installed. Run .\Install-TailscaleService.ps1 first."
    exit 1
}
if ($svc.Status -ne 'Running') {
    Write-Host "Starting service '$($svc.Name)'..."
    Start-Service $svc.Name
    $svc.WaitForStatus('Running', '00:00:30')
    Start-Sleep -Seconds 2   # give tailscaled a moment to open its LocalAPI pipe
}

if (-not $NoUnattended -and -not (Test-Admin)) {
    Write-Warning "Unattended Mode works best from an Administrator PowerShell. If 'tailscale up' complains about permissions, reopen PowerShell as Administrator."
}

# Auth key: parameter, then prompt, then environment.
if ($PromptForAuthKey) {
    $secure = Read-Host -AsSecureString 'Auth key (tskey-auth-...)'
    $AuthKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}
if (-not $AuthKey -and $env:TS_AUTHKEY) { $AuthKey = $env:TS_AUTHKEY }

# With no setting flags, leave every saved setting (exit node, routes, and so
# on) exactly as it is: switch on Unattended Mode with "tailscale set", then
# run a bare "tailscale up", which reuses the saved settings. Passing setting
# flags to "up" would make it insist on restating every non-default setting.
$settingsGiven = $Hostname -or $LoginServer -or $AcceptRoutes -or $ExitNode -or $AdvertiseExitNode -or $Reset

$upArgs = @('up')
if ($settingsGiven) {
    if (-not $NoUnattended)  { $upArgs += '--unattended' }
    if ($Hostname)           { $upArgs += "--hostname=$Hostname" }
    if ($LoginServer)        { $upArgs += "--login-server=$LoginServer" }
    if ($AcceptRoutes)       { $upArgs += '--accept-routes' }
    if ($ExitNode)           { $upArgs += "--exit-node=$ExitNode" }
    if ($AdvertiseExitNode)  { $upArgs += '--advertise-exit-node' }
    if ($Reset)              { $upArgs += '--reset' }
} elseif (-not $NoUnattended) {
    Write-Host "Switching on Unattended Mode (other settings untouched)..."
    & $TailscaleExe set --unattended
    if ($LASTEXITCODE -ne 0) { Write-Warning "'tailscale set --unattended' failed; continuing with login." }
}
if ($ForceReauth)        { $upArgs += '--force-reauth' }

# Keep the key off the command line (where other processes can read it) by
# handing tailscale a file in your own temp folder, deleted right after.
$keyFile = $null
if ($AuthKey) {
    $keyFile = [IO.Path]::GetTempFileName()
    Set-Content -Path $keyFile -Value $AuthKey -NoNewline -Encoding ASCII
    $upArgs += "--auth-key=file:$keyFile"
}

Write-Host "Running: tailscale $(($upArgs | ForEach-Object { if ($_ -like '--auth-key=*') { '--auth-key=<hidden>' } else { $_ } }) -join ' ')"
Write-Host ""

# tailscale prints the login link on stderr and then waits until you've signed
# in. Stream its output, and open the first link we see.
$opened = $false
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'   # stderr lines aren't errors here
try {
    & $TailscaleExe @upArgs 2>&1 | ForEach-Object {
        $line = "$_"
        Write-Host $line
        if (-not $opened -and $line -match '(https://\S+)') {
            $url = $Matches[1]
            if ($NoBrowser) {
                Write-Host "Open that link in a browser to finish logging in." -ForegroundColor Yellow
            } else {
                Write-Host "Opening the login page in your browser..." -ForegroundColor Yellow
                Start-Process $url
            }
            $opened = $true
        }
    }
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
    if ($keyFile) { Remove-Item $keyFile -Force -ErrorAction SilentlyContinue }
}

if ($code -ne 0) {
    Write-Error "tailscale up failed (exit code $code). See the output above."
    exit $code
}

Write-Host ""
Write-Host "Logged in." -ForegroundColor Green
& $TailscaleExe status
Write-Host ""
Write-Host "This machine reconnects by itself after a reboot. To log out: tailscale logout"
