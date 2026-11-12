---
name: anything-to-new-context-menu
description: Put any legacy right-click item (one that only shows under "Show more options") directly on the top level of the Windows 11 context menu, or add a new item that runs a program. Use when the user wants a shell-extension entry such as "Combine Files In Revu", "Open with X" or a custom command to appear in the new Windows 11 right-click menu, asks why an item is only in "Show more options" / "App extensions", or asks to restore/customize Windows 11 context menu entries.
---

# Anything → Windows 11 new context menu

The Windows 11 menu only shows **packaged** `IExplorerCommand` extensions. Legacy `IContextMenu`
shell extensions and `shell\<verb>\command` registry verbs are hidden under *Show more options*.
This skill wraps any such item in a tiny native, signed sparse package so it shows on the main menu.

Everything is in `scripts/`:

| file | purpose |
|---|---|
| `probe.ps1` | list legacy entries for a file: static verbs (with command lines) and COM handlers (with the exact menu texts they add) |
| `src/ContextMenuBridge.cpp` | generic native `IExplorerCommand` DLL driven by `bridge.ini` (forward to a legacy handler, or launch a program) |
| `build.ps1` | downloads toolchain, compiles, creates cert, builds **one signed MSIX per item** from a JSON config |
| `install.ps1` / `uninstall.ps1` | install packages, pin them to the main menu, restart Explorer / undo |
| `../examples/*.json` | config examples (legacy handler, plain command) |

## Workflow

1. **Check the Windows build.** `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | select DisplayVersion,CurrentBuild`.
   Don't spend time on the `{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}` "classic menu" registry hack: it no longer works on newer builds (confirmed on 26300) and isn't what the user asked for anyway.

2. **Find the item.** Make or pick a sample file of the right type, then run:
   `powershell -ExecutionPolicy Bypass -File scripts\probe.ps1 -Path <file> [-Filter <text>]`
   - Item listed under *COM shell extensions* → `mode: "handler"`, `handlerClsid` = that CLSID, `match` = the menu text (substring, `&` ignored).
   - Item listed under *Static verbs* → `mode: "command"`, `program`/`arguments` from the command line (`%*` = all selected paths, `%1` = first path, both quoted).

3. **Write a config** (copy `examples/bluebeam-revu.json`). One entry per menu item. `id` = letters/digits.
   `itemTypes`: `"*"` (all files), `".pdf"`, `"Directory"`, `"Directory\\Background"`.
   `installDir` defaults to `%USERPROFILE%\NewContextMenu`; keep it **outside `%LOCALAPPDATA%`/`%APPDATA%`** (see pitfalls).

4. **Build.** `powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Config <config.json>`
   Downloads ~210 MB of tools on the first run (llvm-mingw from GitHub, Microsoft.Windows.SDK.BuildTools from nuget.org); **get the user's OK before downloading**. Generated CLSIDs are written back into the config; keep it so rebuilds upgrade in place.

5. **Trust the certificate — the user does this, not you** (machine trust change, needs admin):
   double-click `<installDir>\ContextMenuBridge.cer` → Install Certificate → **Local Machine** →
   *Place all certificates in the following store* → **Trusted People**.
   Warn explicitly: leaving the wizard on "automatically select" puts it in *Intermediate Certification Authorities* and install fails with `0x800B0109`. Verify with
   `Get-ChildItem Cert:\LocalMachine\TrustedPeople | ? Subject -eq 'CN=ContextMenuBridge'`.

6. **Install.** `powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -InstallDir <installDir>`
   It installs each MSIX with `-ExternalLocation`, writes the main-menu preference, closes Settings and restarts Explorer.

7. **Verify with the user** (you can't see the menu): items appear on the top level together with the others, and clicking does the right thing. Failures are logged to `<installDir>\<id>\error.log`.

To remove: `uninstall.ps1 -InstallDir <dir> [-RemoveFiles]`; the user removes the cert in `certlm.msc` themselves.

## How it works / pitfalls (all hit in practice)

- **One verb per package.** Two verbs in one package are grouped under a submenu named after the package. build.ps1 makes one package per item for this reason.
- **"App extensions" submenu (newer builds, e.g. 26300).** Third-party extensions go into *App extensions* unless enabled in Settings › Personalization › Context menu. The toggle is stored at
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ContextMenu\Preferences\extensions\<PackageFamilyName>` `Enabled=dword:1`.
  (`...\ContextMenu\DefaultState\extensions` is only Windows' default and doesn't work for this.)
- **Only signed packages count.** A loose, unsigned package registered in Developer Mode (`SignatureKind=None`) works but is hidden from the Settings list and ignores the preference, so it stays in the submenu. Hence the self-signed cert + MSIX. Developer Mode is not needed.
- **Settings caches its list.** `SystemSettings.exe` keeps running in the background; kill it before checking the list again.
- **Packaged-app file virtualization.** If your shell runs inside an MSIX app (e.g. an agent's desktop app), writes to `%LOCALAPPDATA%`/`%APPDATA%` land in the app's private `LocalCache`. `Add-AppxPackage` then fails with *"Opening file from location: AppxManifest.xml failed … path not found"*. Use a folder under `%USERPROFILE%` (and run unsandboxed if your tool sandboxes commands).
- **Use native code.** Explorer unloads the extension after each menu, so a .NET (comhost) handler has to start the runtime every time and shows up visibly late. The C++ bridge loads in ~5 ms.
- **Forwarding to a legacy handler** = `IShellItemArray::BindToHandler(BHID_DataObject)` → `IShellExtInit::Initialize` → `IContextMenu::QueryContextMenu` into a hidden menu → find the item by text → `InvokeCommand`. The legacy extension does the real work, so behaviour matches *Show more options* exactly and survives app updates as long as the menu text stays the same.
- Restart Explorer after every install/change (`Stop-Process -Name explorer`; it restarts by itself, otherwise `Start-Process explorer`).
