<#
.SYNOPSIS
  Installs every <id>.msix built by build.ps1 in -InstallDir and pins each item to the
  top level of the Windows 11 context menu.

.DESCRIPTION
  Requires ContextMenuBridge.cer to be trusted in Local Machine > Trusted People. That is a
  machine trust change, so the script does not do it; it prints the steps and exits instead.
#>
param([Parameter(Mandatory)] [string]$InstallDir)
$ErrorActionPreference = 'Stop'
$InstallDir = (Resolve-Path $InstallDir).Path

$cer = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $InstallDir 'ContextMenuBridge.cer')
if (-not (Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq $cer.Thumbprint)) {
    Write-Host @"
The signing certificate is not trusted yet. Please (as the user, needs admin):
  1. Double-click $InstallDir\ContextMenuBridge.cer -> Install Certificate
  2. Store Location: Local Machine
  3. Choose 'Place all certificates in the following store' -> Browse -> Trusted People
     (do NOT leave it on automatic: that puts it in Intermediate Certification Authorities)
  4. Finish, then run this script again.
"@ -ForegroundColor Yellow
    exit 1
}

$prefs = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\ContextMenu\Preferences\extensions'
foreach ($msix in Get-ChildItem $InstallDir -Filter *.msix) {
    $ext = Join-Path $InstallDir $msix.BaseName
    [xml]$m = Get-Content (Join-Path $ext 'AppxManifest.xml')
    $name = $m.Package.Identity.Name
    Add-AppxPackage -Path $msix.FullName -ExternalLocation $ext -ForceApplicationShutdown
    $pfn = (Get-AppxPackage $name).PackageFamilyName
    # Same value the Settings > Personalization > Context menu > App extensions toggle writes.
    New-Item "$prefs\$pfn" -Force | Out-Null
    New-ItemProperty "$prefs\$pfn" -Name Enabled -Value 1 -PropertyType DWord -Force | Out-Null
    Write-Host "installed $name ($pfn)"
}

Stop-Process -Name SystemSettings -Force -ErrorAction SilentlyContinue   # refresh its extension list
Stop-Process -Name explorer -Force
Start-Sleep 2
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
Write-Host 'Done. Right-click a file to check.'
