#Requires -Version 5.1
<#
.SYNOPSIS
    Finds out why the internet feels slow with Tailscale on, fixes what's safe,
    and tells you the rest. Leaves your exit node choice alone.

.DESCRIPTION
    Tailscale only touches traffic that isn't for the tailnet in two cases: an
    exit node is on (then *all* your internet goes through it, and on Windows a
    firewall rule blocks anything that tries to go around it, including your
    own LAN), and MagicDNS is on (then every DNS lookup goes through tailscaled).
    This script measures both and checks a few other usual suspects:

      - Is the exit node reachable directly, or relayed through a DERP server?
        Relayed is the single biggest cause of lag.
      - How much latency does the exit node add? (ping to it vs. ping to 1.1.1.1)
      - Is LAN access allowed while the exit node is on? If not, printers, the
        NAS and the router page are blocked or slow.
      - How long does a DNS lookup take through Tailscale vs. a public resolver?
      - Does another device advertise a subnet route that overlaps your home LAN?
      - Any health warnings tailscaled itself reports.
      - Unattended Mode, wintun.dll and Wake-on-LAN, since you've set those up.

    What it changes (skip with -ReportOnly), each one reversible with the
    printed command:
      - Turns on "allow LAN access" when an exit node is in use. Your exit node
        stays exactly as it is; only traffic for your own LAN stops taking the
        detour. Undo: tailscale set --exit-node-allow-lan-access=false
      - Turns on Unattended Mode if it's off. Undo: tailscale set --unattended=false

    Everything else (DNS, routes, exit node side fixes) is a suggestion with
    the exact command, because each has a trade-off only you can weigh.

.PARAMETER ReportOnly
    Measure and report, change nothing.

.PARAMETER TailscaleExe
    Path to tailscale.exe. Defaults to one next to this script, then PATH.

.EXAMPLE
    .\Tune-Tailscale.ps1
    .\Tune-Tailscale.ps1 -ReportOnly
#>
[CmdletBinding()]
param(
    [switch]$ReportOnly,
    [string]$TailscaleExe
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Native tools write progress to stderr; don't let PowerShell 5.1 treat that as fatal.
function Invoke-Quiet([scriptblock]$Body) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Body } finally { $ErrorActionPreference = $old }
}
function Section([string]$t) { Write-Host ""; Write-Host "== $t" -ForegroundColor Cyan }
function Ok([string]$t)      { Write-Host "   [ok]   $t" -ForegroundColor Green }
function Info([string]$t)    { Write-Host "   [..]   $t" }
function Warn([string]$t)    { Write-Host "   [!!]   $t" -ForegroundColor Yellow }
$applied = New-Object Collections.ArrayList
$suggest = New-Object Collections.ArrayList
function Fixed([string]$t)   { Write-Host "   [done] $t" -ForegroundColor Green; [void]$applied.Add($t) }
function Suggest([string]$why, [string]$cmd) {
    Write-Host "   [fix]  $why" -ForegroundColor Yellow
    Write-Host "          $cmd" -ForegroundColor White
    [void]$suggest.Add("$why`n          $cmd")
}

# --- find tailscale.exe and talk to the daemon ----------------------------------

if (-not $TailscaleExe) {
    $TailscaleExe = @(
        (Join-Path $PSScriptRoot 'tailscale.exe'),
        (Get-Command tailscale.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $TailscaleExe) { throw "Couldn't find tailscale.exe. Pass -TailscaleExe." }
$ts = $TailscaleExe

function Ts([string[]]$ArgList) {
    Invoke-Quiet { & $ts @ArgList 2>&1 | ForEach-Object { "$_" } }
}

Section 'Service'
$svc = Get-Service Tailscale -ErrorAction SilentlyContinue
if (-not $svc) { throw "No 'Tailscale' service. Run Install-TailscaleService.ps1 first." }
if ($svc.Status -ne 'Running') { Warn "Service is $($svc.Status)"; Start-Service Tailscale; Start-Sleep 2 }
Ok "Service $($svc.Status), start type $($svc.StartType)"

$status = (Ts @('status', '--json') | Out-String | ConvertFrom-Json)
$prefs  = (Ts @('debug', 'prefs')   | Out-String | ConvertFrom-Json)
$selfName = if ($status.Self -and $status.Self.DNSName) { $status.Self.DNSName.TrimEnd('.') } else { '(not logged in)' }
Info "tailscale $($status.Version), state $($status.BackendState), this node: $selfName"
if ($status.BackendState -ne 'Running') { Warn "Not connected ($($status.BackendState)). Run Connect-Tailscale.ps1, then this again." }

$exeDir = Split-Path $ts
if (Test-Path (Join-Path $exeDir 'wintun.dll')) { Ok 'wintun.dll is next to the exe' }
else { Warn "wintun.dll missing from $exeDir; the network adapter can't be created without it" }

if ($status.Health) { foreach ($h in $status.Health) { Warn "tailscaled says: $h" } }
else { Ok 'No health warnings from tailscaled' }

if ($prefs.ForceDaemon) { Ok 'Unattended Mode on (stays connected at the lock screen and after sign-out)' }
elseif ($ReportOnly)    { Suggest 'Unattended Mode is off; the tunnel drops when you sign out of Windows' 'tailscale set --unattended' }
else { Ts @('set', '--unattended') | Out-Null; Fixed 'Unattended Mode turned on (undo: tailscale set --unattended=false)' }

# --- exit node -------------------------------------------------------------------

Section 'Exit node (this is where internet lag comes from, if anywhere)'
$peers = @()
if ($status.Peer) { $peers = @($status.Peer.PSObject.Properties | ForEach-Object { $_.Value }) }
$exit = $peers | Where-Object { $_.ExitNode } | Select-Object -First 1

function Measure-Ping([string]$Target) {
    $r = Test-Connection -ComputerName $Target -Count 4 -ErrorAction SilentlyContinue
    if (-not $r) { return $null }
    $vals = $r | ForEach-Object { if ($_.PSObject.Properties['Latency']) { $_.Latency } else { $_.ResponseTime } }
    return [math]::Round(($vals | Measure-Object -Average).Average)
}

if (-not $exit) {
    Ok 'No exit node in use: your internet traffic does not go through Tailscale at all'
    $inet = Measure-Ping '1.1.1.1'
    if ($inet -ne $null) { Info "Internet round trip to 1.1.1.1: ${inet} ms (Tailscale is not in that path)" }
} else {
    $name = $exit.DNSName.TrimEnd('.').Split('.')[0]
    Info "Exit node: $name ($($exit.TailscaleIPs[0])), online=$($exit.Online)"
    if (-not $exit.Online) { Warn "The exit node is offline. Until it's back, all internet traffic is blocked." }

    # Direct or relayed? One ping also makes tailscaled try for a direct path.
    $pingOut = Ts @('ping', '-c', '3', '--timeout', '3s', "$($exit.TailscaleIPs[0])")
    $last = $pingOut | Where-Object { $_ -match 'pong from' } | Select-Object -Last 1
    $viaRtt = $null
    if ($last -match 'via (.+?) in ([\d.]+)(ms|s)\b') {
        $via = $Matches[1]
        $viaRtt = [double]$Matches[2]; if ($Matches[3] -eq 's') { $viaRtt *= 1000 }
        $viaRtt = [math]::Round($viaRtt)
        if ($via -like 'DERP*') {
            Warn "Connection to the exit node is RELAYED through a Tailscale server ($via), ${viaRtt} ms. That is the usual cause of slow internet."
            Suggest "Fix this on the exit node, not here: let UDP port 41641 in through its firewall/router (or enable UPnP there), then check with" "tailscale ping $name"
        } else {
            Ok "Direct connection to the exit node ($via), ${viaRtt} ms round trip"
        }
    } else {
        Warn "Couldn't ping the exit node: $($pingOut -join ' ')"
    }

    $inet = Measure-Ping '1.1.1.1'
    if ($inet -ne $null) {
        Info "Internet round trip to 1.1.1.1 through the exit node: ${inet} ms"
        if ($viaRtt -ne $null) {
            Info "Of that, about ${viaRtt} ms is the hop to the exit node; the rest is the exit node's own internet."
            if ($inet -gt 150) { Warn "Over 150 ms to the internet is noticeable. Every site you open pays this." }
        }
    }

    if ($prefs.ExitNodeAllowLANAccess) {
        Ok 'LAN access allowed: printers, NAS and router page bypass the exit node'
    } else {
        $why = 'LAN access is OFF: with an exit node on, Windows Tailscale blocks traffic to your own LAN (printer, NAS, router page) or sends it the long way round'
        if ($ReportOnly) { Suggest $why 'tailscale set --exit-node-allow-lan-access' }
        else {
            Ts @('set', '--exit-node-allow-lan-access') | Out-Null
            Fixed 'LAN access allowed while the exit node stays as it is (undo: tailscale set --exit-node-allow-lan-access=false)'
        }
    }

    Info "If you want internet traffic to stop going through the exit node, that's your call: tailscale set --exit-node="
}

# --- DNS -------------------------------------------------------------------------

Section 'DNS'
if (-not $prefs.CorpDNS) {
    Ok 'Tailscale is not managing DNS; lookups use your normal resolver'
} elseif (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
    function Measure-Dns([string]$Server) {
        $name = "t$(Get-Random -Maximum 999999).example.com"   # uncached on purpose
        $t = Measure-Command { Resolve-DnsName $name -Server $Server -DnsOnly -ErrorAction SilentlyContinue | Out-Null }
        return [math]::Round($t.TotalMilliseconds)
    }
    $viaTs  = Measure-Dns '100.100.100.100'
    $direct = Measure-Dns '1.1.1.1'
    Info "Lookup through Tailscale (100.100.100.100): ${viaTs} ms; straight to 1.1.1.1: ${direct} ms"
    if ($viaTs -gt ($direct + 100)) {
        Suggest "DNS through Tailscale is $($viaTs - $direct) ms slower. Turning it off makes every site start faster, but you lose MagicDNS names (use IPs or 'tailscale status' instead)" 'tailscale set --accept-dns=false'
    } else {
        Ok 'DNS through Tailscale is not adding noticeable delay'
    }
} else {
    Info 'Resolve-DnsName not available; skipped the DNS timing'
}

# --- subnet routes overlapping the home LAN -------------------------------------

Section 'Subnet routes'
function Test-IpInPrefix([string]$Ip, [string]$Prefix) {
    $net, $bits = $Prefix.Split('/')
    if ($Ip -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $net -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $false }
    $toInt = { param($a) $b = [IPAddress]::Parse($a).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
    $mask = if ([int]$bits -eq 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - [int]$bits)) }
    return ((& $toInt $Ip) -band $mask) -eq ((& $toInt $net) -band $mask)
}
$localIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' -and $_.IPAddress -notlike '100.*' -and $_.IPAddress -notlike '169.254.*' }
$conflicts = @()
foreach ($p in $peers) {
    if (-not $p.PrimaryRoutes) { continue }
    foreach ($route in @($p.PrimaryRoutes)) {
        if ($route -in '0.0.0.0/0', '::/0') { continue }
        foreach ($l in $localIps) {
            if (Test-IpInPrefix $l.IPAddress $route) { $conflicts += "$route from $($p.DNSName.TrimEnd('.').Split('.')[0]) overlaps your LAN ($($l.IPAddress))" }
        }
    }
}
if (-not $prefs.RouteAll) { Ok 'Not accepting subnet routes, so none can shadow your LAN' }
elseif ($conflicts) {
    foreach ($c in $conflicts) { Warn $c }
    Suggest 'Traffic for your own LAN is being sent across the tailnet. Either stop that device advertising the route, or stop accepting routes here' 'tailscale set --accept-routes=false'
} else { Ok 'No advertised route overlaps your LAN' }

# --- Wake-on-LAN ------------------------------------------------------------------

Section 'Wake-on-LAN'
$envFile = Join-Path $env:ProgramData 'Tailscale\tailscaled-env.txt'
$mac = if (Test-Path $envFile) { (Select-String -Path $envFile -Pattern '^\s*TS_WAKE_MAC\s*=\s*(.+)$' | Select-Object -First 1).Matches.Groups[1].Value } else { $null }
$armed = Invoke-Quiet { & powercfg.exe /devicequery wake_armed 2>&1 | Where-Object { "$_" -and "$_" -notmatch '^NONE$' } }
if ($mac -and $armed) { Ok "Advertising MAC $mac; wake-armed: $(($armed -join ', ').Trim())" }
elseif ($mac) { Suggest "MAC $mac is advertised but no network adapter is armed to wake the PC" '.\Enable-WakeOnLan.ps1' }
else { Suggest 'This PC cannot be woken from sleep yet' '.\Enable-WakeOnLan.ps1' }

# --- summary ---------------------------------------------------------------------

Section 'Summary'
if ($applied.Count) { Write-Host "   Changed now:" -ForegroundColor Green; $applied | ForEach-Object { Write-Host "     - $_" } }
else { Write-Host "   Nothing changed." }
if ($suggest.Count) {
    Write-Host "   Your call (each has a trade-off):" -ForegroundColor Yellow
    $suggest | ForEach-Object { Write-Host "     - $_" }
} else { Write-Host "   Nothing else to suggest; the setup looks right." -ForegroundColor Green }
