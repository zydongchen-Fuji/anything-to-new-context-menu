<#
.SYNOPSIS
  Removes the packages installed from -InstallDir and their main-menu preference.
  -RemoveFiles also deletes the install folder. The trusted certificate is left for the user
  to remove (certlm.msc > Trusted People) because it is a machine trust setting.
#>
param(
    [Parameter(Mandatory)] [string]$InstallDir,
    [switch]$RemoveFiles
)
$ErrorActionPreference = 'Stop'
$prefs = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ContextMenu\Preferences\extensions'
foreach ($manifest in Get-ChildItem $InstallDir -Filter AppxManifest.xml -Recurse -Depth 1) {
    [xml]$m = Get-Content $manifest.FullName
    $p = Get-AppxPackage $m.Package.Identity.Name
    if ($p) {
        Remove-Item "$prefs\$($p.PackageFamilyName)" -Recurse -Force -ErrorAction SilentlyContinue
        $p | Remove-AppxPackage
        Write-Host "removed $($p.Name)"
    }
}
Stop-Process -Name explorer -Force
Start-Sleep 2
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
if ($RemoveFiles) { Remove-Item $InstallDir -Recurse -Force }
