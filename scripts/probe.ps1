<#
.SYNOPSIS
  Lists the legacy ("Show more options") context-menu entries Windows would show for a file,
  so you can pick what to bring to the Windows 11 menu.

.DESCRIPTION
  For the given file it checks the registry locations that feed the classic menu
  (*, AllFilesystemObjects, the extension, its ProgID, SystemFileAssociations) and prints:
    - static verbs (shell\<verb>\command)  -> use Mode=command
    - COM shell extensions (shellex\ContextMenuHandlers) and the menu texts each one adds
                                           -> use Mode=handler with HandlerClsid + Match
  Nothing is invoked; handlers are only asked to fill a hidden menu.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File probe.ps1 -Path C:\temp\sample.pdf
  powershell -ExecutionPolicy Bypass -File probe.ps1 -Path C:\temp\sample.pdf -Filter Revu
#>
param(
    [Parameter(Mandatory)] [string]$Path,
    [string]$Filter = ''
)
$ErrorActionPreference = 'Stop'
$Path = (Resolve-Path $Path).Path
if (-not [Environment]::Is64BitProcess) { Write-Warning 'Run this from 64-bit PowerShell: Explorer is 64-bit.' }

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class Probe {
    [ComImport, Guid("000214E8-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellExtInit { [PreserveSig] int Initialize(IntPtr pidl, IntPtr dataObj, IntPtr hkey); }
    [ComImport, Guid("000214E4-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IContextMenu { [PreserveSig] int QueryContextMenu(IntPtr hmenu, uint index, uint first, uint last, uint flags); }
    [ComImport, Guid("b63ea76d-1f85-456f-a19c-48159efa858b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemArray { [PreserveSig] int BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv); }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHCreateItemFromParsingName(string p, IntPtr pbc, ref Guid riid, out IntPtr ppv);
    [DllImport("shell32.dll")] static extern int SHCreateShellItemArrayFromShellItem(IntPtr psi, ref Guid riid, out IShellItemArray ppv);
    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll")] static extern bool DestroyMenu(IntPtr h);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr h, int pos);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuStringW(IntPtr h, uint item, StringBuilder s, int max, uint flags);

    static IntPtr DataObject(string path) {
        Guid iidItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), iidArr = new Guid("b63ea76d-1f85-456f-a19c-48159efa858b");
        IntPtr item; Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(path, IntPtr.Zero, ref iidItem, out item));
        IShellItemArray arr; Marshal.ThrowExceptionForHR(SHCreateShellItemArrayFromShellItem(item, ref iidArr, out arr));
        Guid bhid = new Guid("B8C0BD9F-ED24-455c-83E6-D5390C4FE8C4"), iid = new Guid("0000010e-0000-0000-C000-000000000046");
        IntPtr dobj; Marshal.ThrowExceptionForHR(arr.BindToHandler(IntPtr.Zero, ref bhid, ref iid, out dobj));
        return dobj;
    }

    static void Walk(IntPtr m, string indent, List<string> outp) {
        int n = GetMenuItemCount(m);
        for (int i = 0; i < n; i++) {
            var sb = new StringBuilder(512);
            GetMenuStringW(m, (uint)i, sb, 512, 0x400);
            string t = sb.ToString().Replace("&", "");
            IntPtr sub = GetSubMenu(m, i);
            if (t.Length > 0) outp.Add(indent + t + (sub != IntPtr.Zero ? "  >" : ""));
            if (sub != IntPtr.Zero) Walk(sub, indent + "    ", outp);
        }
    }

    // Raw vtable calls: handlers written in .NET Framework would otherwise come back as plain
    // managed objects (same CLR as PowerShell 5.1) and refuse the interface casts.
    [DllImport("ole32.dll")] static extern int CoCreateInstance(ref Guid clsid, IntPtr outer, uint ctx, ref Guid iid, out IntPtr ppv);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int InitFn(IntPtr self, IntPtr pidl, IntPtr dobj, IntPtr hkey);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int QcmFn(IntPtr self, IntPtr hmenu, uint index, uint first, uint last, uint flags);
    static T Slot<T>(IntPtr obj, int slot) {
        IntPtr vt = Marshal.ReadIntPtr(obj);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, slot * IntPtr.Size), typeof(T));
    }

    public static string[] Items(string path, string clsid) {
        var outp = new List<string>();
        IntPtr dobj = DataObject(path);
        IntPtr menu = CreatePopupMenu();
        IntPtr init = IntPtr.Zero, cm = IntPtr.Zero;
        try {
            Guid c = new Guid(clsid), iidInit = new Guid("000214E8-0000-0000-C000-000000000046"), iidCm = new Guid("000214E4-0000-0000-C000-000000000046");
            int hr = CoCreateInstance(ref c, IntPtr.Zero, 1 /*INPROC_SERVER*/, ref iidInit, out init);
            if (hr < 0) { outp.Add("(not an IShellExtInit handler 0x" + hr.ToString("X8") + ")"); return outp.ToArray(); }
            hr = Slot<InitFn>(init, 3)(init, IntPtr.Zero, dobj, IntPtr.Zero);
            if (hr < 0) { outp.Add("(Initialize failed 0x" + hr.ToString("X8") + ")"); return outp.ToArray(); }
            hr = Marshal.QueryInterface(init, ref iidCm, out cm);
            if (hr < 0) { outp.Add("(not an IContextMenu handler)"); return outp.ToArray(); }
            hr = Slot<QcmFn>(cm, 3)(cm, menu, 0, 1, 0x7FFF, 0);
            if (hr < 0) { outp.Add("(QueryContextMenu failed 0x" + hr.ToString("X8") + ")"); return outp.ToArray(); }
            Walk(menu, "", outp);
        } catch (Exception e) {
            outp.Add("(" + e.GetType().Name + ": " + e.Message.Split('\n')[0].Trim() + ")");
        } finally {
            DestroyMenu(menu);
            if (cm != IntPtr.Zero) Marshal.Release(cm);
            if (init != IntPtr.Zero) Marshal.Release(init);
            Marshal.Release(dobj);
        }
        return outp.ToArray();
    }
}
'@

$ext = [IO.Path]::GetExtension($Path)
$keys = @('*', 'AllFilesystemObjects')
if ($ext) {
    $keys += $ext, "SystemFileAssociations\$ext"
    $progId = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$ext" -ErrorAction SilentlyContinue).'(default)'
    if ($progId) { $keys += $progId }
    $perceived = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$ext" -ErrorAction SilentlyContinue).PerceivedType
    if ($perceived) { $keys += "SystemFileAssociations\$perceived" }
}

Write-Host "`n== Static verbs (use Mode=command) ==" -ForegroundColor Cyan
foreach ($k in $keys) {
    $shell = "Registry::HKEY_CLASSES_ROOT\$k\shell"
    if (-not (Test-Path -LiteralPath $shell)) { continue }
    foreach ($v in Get-ChildItem -LiteralPath $shell) {
        $props = Get-ItemProperty -LiteralPath $v.PSPath
        $label = if ($props.MUIVerb) { $props.MUIVerb } elseif ($props.'(default)') { $props.'(default)' } else { $v.PSChildName }
        $cmd = (Get-ItemProperty -LiteralPath "$($v.PSPath)\command" -ErrorAction SilentlyContinue).'(default)'
        if (-not $cmd) { continue }
        if ($Filter -and "$label $cmd" -notmatch [regex]::Escape($Filter)) { continue }
        "[$k] $label`n    command: $cmd"
    }
}

Write-Host "`n== COM shell extensions (use Mode=handler) ==" -ForegroundColor Cyan
$seen = @{}
foreach ($k in $keys) {
    $hk = "Registry::HKEY_CLASSES_ROOT\$k\shellex\ContextMenuHandlers"
    if (-not (Test-Path -LiteralPath $hk)) { continue }
    foreach ($h in Get-ChildItem -LiteralPath $hk) {
        $clsid = (Get-ItemProperty -LiteralPath $h.PSPath).'(default)'
        if ($clsid -notmatch '^\{[0-9a-fA-F-]{36}\}$') { $clsid = $h.PSChildName }
        if ($clsid -notmatch '^\{[0-9a-fA-F-]{36}\}$' -or $seen[$clsid]) { continue }
        $seen[$clsid] = 1
        $name = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid" -ErrorAction SilentlyContinue).'(default)'
        $items = [Probe]::Items($Path, $clsid.Trim('{}'))
        $text = "[$k] $($h.PSChildName)  $clsid  $name"
        if ($Filter -and ($text + ($items -join ' ')) -notmatch [regex]::Escape($Filter)) { continue }
        $text
        foreach ($i in $items) { "    $i" }
    }
}
