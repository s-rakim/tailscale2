# Run tailscaled as a Windows service (auto-start, no tray icon)

These two scripts register your build of `tailscaled.exe` as a normal Windows
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
| `Install-TailscaleService.ps1` | Creates the service with Automatic start and starts it |
| `Uninstall-TailscaleService.ps1` | Stops and deletes the service (keeps your login state) |

Both use `tailscaled install-system-daemon` / `uninstall-system-daemon`, which
are built into `tailscaled.exe` (see `cmd/tailscaled/install_windows.go`). If
you pick a custom service name, they use `New-Service` / `sc.exe` instead.

## Before you start: the official app and its tray icon

If you have the official Tailscale app installed, it already owns a service
called `Tailscale`, and it's what puts the icon in your tray. Pick one:

1. **Drop the official app (no tray icon at all).** First copy
   `C:\Program Files\Tailscale\wintun.dll` somewhere safe (you'll need it in a
   minute), then uninstall Tailscale from *Settings > Apps*. Your login in
   `C:\ProgramData\Tailscale` usually survives, but plan on running
   `tailscale up` again just in case.
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

1. Put `tailscaled.exe` and `tailscale.exe` in a permanent folder, for example
   `C:\Tailscale\`. The service runs the exe from wherever it is, so don't use
   `Downloads`.
2. Put `wintun.dll` in the same folder. This is the network adapter driver
   `tailscaled` needs, and it only looks next to the exe or in System32. Use
   the copy you saved from the official install, or download
   [wintun-0.14.1.zip](https://www.wintun.net/builds/wintun-0.14.1.zip) and take
   `wintun\bin\amd64\wintun.dll` (`arm64` on ARM PCs). The install script
   stops with a clear message if it's missing.
3. Copy both `.ps1` scripts into that same folder.
4. Open **PowerShell as Administrator** (Start, type `powershell`, right-click,
   *Run as administrator*).
5. Run:
   ```powershell
   cd C:\Tailscale
   Unblock-File .\*.exe, .\*.ps1
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Install-TailscaleService.ps1
   ```
   `Set-ExecutionPolicy -Scope Process` only applies to this PowerShell window
   and resets when you close it.
6. Log in once:
   ```powershell
   .\tailscale.exe up
   ```
   After that it reconnects at every boot without you doing anything.

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
