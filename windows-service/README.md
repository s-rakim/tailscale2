# Run tailscaled as a Windows service (auto-start, no tray icon)

These scripts register your build of `tailscaled.exe` as a normal Windows
service that starts automatically at boot and runs in the background.

- **No tray icon.** The tray icon belongs to the GUI app (`tailscale-ipn.exe`),
  not to `tailscaled`. These scripts only install the daemon, so nothing gets
  added to your taskbar.
- **No window.** Windows services don't have a console or UI, so there's nothing
  to close or minimize.
- **Starts at boot**, before anyone logs in, and restarts itself if it crashes.

It's still an ordinary service. You'll see it in `services.msc` and in Task
Manager's Services tab, and you can stop or remove it whenever you want.

## Files

| File | What it does |
|---|---|
| `Install-TailscaleService.ps1` | Puts `wintun.dll` next to `tailscaled.exe`, creates the service with Automatic start and starts it |
| `Remove-OfficialTailscale.ps1` | Uninstalls the official app and its tray GUI, keeping your login state |
| `Connect-Tailscale.ps1` | Logs the machine in without the GUI (opens the login page, or uses an auth key) |
| `Uninstall-TailscaleService.ps1` | Stops and deletes the service (keeps your login state) |
| `wintun\` | Signed `wintun.dll` 0.14.1 for amd64 and arm64, plus its license. See `wintun\README.md` |

You don't need anything from the official Tailscale app. The network driver
ships in `wintun\`, so this works on a machine that has never had Tailscale
installed.

Both use `tailscaled install-system-daemon` / `uninstall-system-daemon`, which
are built into `tailscaled.exe` (see `cmd/tailscaled/install_windows.go`). If
you pick a custom service name, they use `New-Service` / `sc.exe` instead.

## Before you start: the official app and its tray icon

If you have the official Tailscale app installed, it already owns a service
called `Tailscale`, and it's what puts the icon in your tray. Pick one:

1. **Drop the official app (no tray icon at all).** From an Administrator
   PowerShell in this folder, run `.\Remove-OfficialTailscale.ps1`. It closes
   the tray app, backs up `C:\ProgramData\Tailscale`, runs the official
   uninstaller silently, and puts your login state back if the uninstaller
   removed it. You don't need anything else from the official app; the driver
   comes from `wintun\`. (Uninstalling from *Settings > Apps* works too.)
2. **Keep the official app but hide the icon.** Leave the app installed and
   turn off *Tailscale* in *Settings > Apps > Startup* (or Task Manager >
   Startup apps). The service keeps running and the GUI no longer launches at
   login. If you'd rather keep it running, Windows 11 also lets you hide it
   under *Settings > Personalization > Taskbar > Other system tray icons*.
   You don't need these scripts for this option, since the official service is
   already set to Automatic. Just swap in your `.exe` files as described in
   `INSTALL-WINDOWS.md`.

The rest of this page assumes option 1.

## Install

1. Make a permanent folder, for example `C:\Tailscale\`. The service runs the
   exe from wherever it is, so don't use `Downloads`. Lay it out like this:
   ```
   C:\Tailscale\
     tailscaled.exe
     tailscale.exe
     Install-TailscaleService.ps1
     Connect-Tailscale.ps1
     Remove-OfficialTailscale.ps1
     Uninstall-TailscaleService.ps1
     wintun\
       LICENSE.txt
       amd64\wintun.dll
       arm64\wintun.dll
   ```
   That's the `windows-service` folder from this repo with your two `.exe`
   files dropped in.
2. Open **PowerShell as Administrator** (Start, type `powershell`, right-click,
   *Run as administrator*).
3. Run:
   ```powershell
   cd C:\Tailscale
   Get-ChildItem -Recurse | Unblock-File
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Remove-OfficialTailscale.ps1     # skip if the official app is already gone
   .\Install-TailscaleService.ps1
   ```
   `Set-ExecutionPolicy -Scope Process` only applies to this PowerShell window
   and resets when you close it.

   The script works out whether `tailscaled.exe` is amd64 or arm64, checks the
   matching `wintun.dll` against its known SHA-256 and WireGuard LLC's code
   signature, and copies it to `C:\Tailscale\wintun.dll`. tailscaled only looks
   for the DLL **in the same folder as `tailscaled.exe`** or in System32, so
   that's where it has to end up. If you move `tailscaled.exe`, move
   `wintun.dll` with it.
4. Log in once:
   ```powershell
   .\Connect-Tailscale.ps1
   ```
   It opens the Tailscale login page in your browser and returns once you've
   signed in. After that the machine reconnects at every boot by itself, even
   before anyone logs in to Windows.

## Logging in without the GUI

`Connect-Tailscale.ps1` wraps `tailscale up --unattended`. Unattended Mode
makes the connection belong to the machine instead of your Windows account,
which is what you want when there's no tray app.

```powershell
.\Connect-Tailscale.ps1                              # browser login
.\Connect-Tailscale.ps1 -PromptForAuthKey            # paste an auth key instead
.\Connect-Tailscale.ps1 -Hostname latitude -AcceptRoutes
.\Connect-Tailscale.ps1 -ExitNode nas                # send internet traffic via "nas"
.\Connect-Tailscale.ps1 -NoBrowser                   # just print the link
```

Auth keys come from the admin console under *Settings > Keys*. The script
passes the key to tailscale through a temp file rather than the command line,
and deletes it afterwards. Run `Get-Help .\Connect-Tailscale.ps1 -Full` for
every option.

To log out: `.\tailscale.exe logout`.

To check on it:

```powershell
Get-Service Tailscale        # Status should be Running, StartType Automatic
.\tailscale.exe status
```

### Running alongside the official app

If you want to keep the official app installed and run your fork too, give the
service its own name:

```powershell
.\Install-TailscaleService.ps1 -ServiceName TailscaleFork
```

Two daemons on one machine will fight over the same state directory and
network interface, so only do this if you know you need it. Option 1 or 2 above
is the better route for most setups.

### Options

| Parameter | Default | Meaning |
|---|---|---|
| `-BinaryPath` | `tailscaled.exe` next to the script, then `C:\Program Files\Tailscale\tailscaled.exe` | Which exe the service runs |
| `-ServiceName` | `Tailscale` | Name of the service |
| `-Start` | `$true` | Start the service right away |

## Uninstall

```powershell
cd C:\Tailscale
.\Uninstall-TailscaleService.ps1             # or -ServiceName TailscaleFork
```

This removes only the service. Your `.exe` files and login state stay put, so
you can reinstall later without logging in again.

## Updating to a new build

```powershell
Stop-Service Tailscale
Copy-Item .\new\tailscaled.exe C:\Tailscale\tailscaled.exe -Force
Start-Service Tailscale
```

The service keeps pointing at the same path, so you don't need to reinstall it.
