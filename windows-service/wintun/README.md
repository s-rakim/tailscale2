# Vendored wintun 0.14.1

`tailscaled.exe` needs `wintun.dll` to create its network adapter. The official
Tailscale installer drops one next to its exe; this folder lets a fork install
work on a machine that has never had the official app.

| File | SHA-256 |
|---|---|
| `amd64/wintun.dll` | `e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce` |
| `arm64/wintun.dll` | `f7ba89005544be9d85231a9e0d5f23b2d15b3311667e2dad0debd344918a3f80` |
| `LICENSE.txt` | the license that ships inside the zip, unchanged |

These are the files from `wintun/bin/<arch>/` in
https://www.wintun.net/builds/wintun-0.14.1.zip (zip SHA-256
`07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51`, the same
version and hash pinned in `tsconst/wintun`). The DLLs are signed by
WireGuard LLC; `Install-TailscaleService.ps1` checks both the hash and the
Authenticode signature before it copies one into place.

## License

The wintun *source* is GPL-2.0/MIT, but these prebuilt DLLs are covered by
WireGuard LLC's "Prebuilt Binaries License" in `LICENSE.txt`. It allows
redistributing the unmodified DLL alongside software that only talks to it
through the `wintun.h` API, which is how tailscaled uses it (via
`golang.zx2c4.com/wintun`). So: don't patch or rename the DLL, and keep
`LICENSE.txt` next to it whenever you hand the bundle to someone.

## Updating

1. Bump `tsconst/wintun` (version, URL, zip SHA-256).
2. Download the new zip from wintun.net and check its SHA-256.
3. Replace `amd64/wintun.dll`, `arm64/wintun.dll` and `LICENSE.txt` with the
   copies from the zip.
4. Update the hashes in this file and in `$WintunHashes` at the top of
   `Install-TailscaleService.ps1`.
