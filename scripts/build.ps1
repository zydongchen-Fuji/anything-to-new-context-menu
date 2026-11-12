<#
.SYNOPSIS
  Builds one signed sparse MSIX package per context-menu item described in a JSON config.

.DESCRIPTION
  1. Downloads (once) llvm-mingw (GitHub, mstorsjo/llvm-mingw) and
     Microsoft.Windows.SDK.BuildTools (nuget.org) into -ToolsDir.
  2. Compiles ContextMenuBridge.dll (native IExplorerCommand) and a placeholder stub exe.
  3. Finds or creates a self-signed code-signing certificate whose subject = config.publisher
     (CurrentUser\My) and exports the public part to <installDir>\ContextMenuBridge.cer.
  4. For every item: creates <installDir>\<id>\ with the DLL, bridge.ini, logo and manifest,
     then packs and signs <installDir>\<id>.msix.
  Generated CLSIDs are written back into the config so rebuilds upgrade the same packages.

  installDir must NOT be under %LOCALAPPDATA% / %APPDATA% when this runs inside a packaged app
  (e.g. an MSIX-installed terminal or agent): those writes are virtualized and the AppX
  deployment service will not find the files.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File build.ps1 -Config ..\examples\bluebeam-revu.json
#>
param(
    [Parameter(Mandatory)] [string]$Config,
    [string]$ToolsDir = (Join-Path $env:USERPROFILE '.ctxmenu-tools')
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Config = (Resolve-Path $Config).Path
$cfg = Get-Content $Config -Raw | ConvertFrom-Json

$installDir = [Environment]::ExpandEnvironmentVariables($cfg.installDir)
if (-not $installDir) { $installDir = Join-Path $env:USERPROFILE 'NewContextMenu' }
$publisher = if ($cfg.publisher) { $cfg.publisher } else { 'CN=ContextMenuBridge' }
$publisherDisplay = if ($cfg.publisherDisplayName) { $cfg.publisherDisplayName } else { 'Local' }
New-Item -ItemType Directory -Force $installDir, $ToolsDir | Out-Null

# ---------- 1. tools ----------
$clang = Get-ChildItem "$ToolsDir\llvm\*\bin\x86_64-w64-mingw32-clang++.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $clang) {
    Write-Host 'Downloading llvm-mingw (~190 MB)...'
    $rel = Invoke-RestMethod 'https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest' -Headers @{ 'User-Agent' = 'ctxmenu-build' }
    $asset = $rel.assets | Where-Object name -match 'ucrt-x86_64\.zip$' | Select-Object -First 1
    Invoke-WebRequest $asset.browser_download_url -OutFile "$ToolsDir\llvm.zip" -UseBasicParsing
    Expand-Archive "$ToolsDir\llvm.zip" "$ToolsDir\llvm" -Force
    Remove-Item "$ToolsDir\llvm.zip"
    $clang = Get-ChildItem "$ToolsDir\llvm\*\bin\x86_64-w64-mingw32-clang++.exe" | Select-Object -First 1
}
$makeappx = Get-ChildItem "$ToolsDir\sdkbt\bin\*\x64\makeappx.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
if (-not $makeappx) {
    Write-Host 'Downloading Microsoft.Windows.SDK.BuildTools (~22 MB)...'
    Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools' -OutFile "$ToolsDir\sdkbt.zip" -UseBasicParsing
    Expand-Archive "$ToolsDir\sdkbt.zip" "$ToolsDir\sdkbt" -Force
    Remove-Item "$ToolsDir\sdkbt.zip"
    $makeappx = Get-ChildItem "$ToolsDir\sdkbt\bin\*\x64\makeappx.exe" | Select-Object -Last 1
}
$signtool = Join-Path $makeappx.DirectoryName 'signtool.exe'
foreach ($t in $makeappx.FullName, $signtool) {
    if ((Get-AuthenticodeSignature $t).Status -ne 'Valid') { throw "$t is not validly signed" }
}

# ---------- 2. compile ----------
$out = Join-Path $ToolsDir 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$libs = '-lole32', '-lshell32', '-lshlwapi', '-luuid', '-luser32', '-ladvapi32'
& $clang.FullName -O2 -shared -static -fno-exceptions -fno-rtti -municode -s -o "$out\ContextMenuBridge.dll" `
    "$here\src\ContextMenuBridge.cpp" "$here\src\ContextMenuBridge.def" @libs
if ($LASTEXITCODE) { throw 'compiling ContextMenuBridge.dll failed' }
& $clang.FullName -O2 -static -municode -mwindows -s -o "$out\ContextMenuBridgeStub.exe" "$here\src\Stub.cpp"
if ($LASTEXITCODE) { throw 'compiling stub failed' }

# ---------- 3. certificate ----------
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $publisher -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } | Select-Object -First 1
if (-not $cert) {
    Write-Host "Creating self-signed certificate $publisher"
    $cert = New-SelfSignedCertificate -Type Custom -Subject $publisher -KeyUsage DigitalSignature `
        -FriendlyName 'Context menu bridge (local)' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
}
Export-Certificate -Cert $cert -FilePath (Join-Path $installDir 'ContextMenuBridge.cer') | Out-Null

# ---------- 4. packages ----------
function Escape-Xml([string]$s) { [Security.SecurityElement]::Escape($s) }

function Save-Logo([string]$icon, [string]$title, [string]$dest) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 150, 150
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $file = if ($icon) { ($icon -split ',')[0].Trim('"') } else { '' }
    if ($file -and (Test-Path $file)) {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($file)
        $g.DrawImage($ico.ToBitmap(), 0, 0, 150, 150)
    } else {
        $g.Clear([System.Drawing.Color]::FromArgb(0, 95, 184))
        $font = New-Object System.Drawing.Font 'Segoe UI', 64, ([System.Drawing.FontStyle]::Bold)
        $fmt = New-Object System.Drawing.StringFormat
        $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $g.DrawString($title.Substring(0, 1), $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 150, 150), $fmt)
    }
    $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

$now = Get-Date
$version = '1.{0}.{1}.0' -f (($now.Year % 100) * 1000 + $now.DayOfYear), ($now.Hour * 60 + $now.Minute)
$template = Get-Content "$here\AppxManifest.template.xml" -Raw
$changed = $false

foreach ($item in $cfg.items) {
    if ($item.id -notmatch '^[A-Za-z][A-Za-z0-9]{0,40}$') { throw "item id '$($item.id)' must be letters/digits only" }
    if (-not $item.PSObject.Properties['clsid'] -or -not $item.clsid) {
        $item | Add-Member -NotePropertyName clsid -NotePropertyValue ('{' + [guid]::NewGuid() + '}') -Force
        $changed = $true
    }
    $clsid = $item.clsid.Trim('{}').ToLower()
    $mode = if ($item.mode) { $item.mode } else { 'handler' }
    $icon = [Environment]::ExpandEnvironmentVariables([string]$item.icon)
    $program = [Environment]::ExpandEnvironmentVariables([string]$item.program)
    $types = if ($item.itemTypes) { @($item.itemTypes) } else { @('*') }
    $dir = Join-Path $installDir $item.id
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item "$out\ContextMenuBridge.dll", "$out\ContextMenuBridgeStub.exe" $dir -Force

    $ini = @('[Command]', "Clsid={$clsid}", "Title=$($item.title)", "Icon=$icon", "Mode=$mode")
    if ($mode -eq 'command') { $ini += "Program=$program", "Arguments=$(if ($item.arguments) { $item.arguments } else { '%*' })" }
    else { $ini += "HandlerClsid=$($item.handlerClsid)", "Match=$($item.match)" }
    Set-Content "$dir\bridge.ini" $ini -Encoding Unicode   # UTF-16 so non-ASCII titles survive

    Save-Logo $icon $item.title "$dir\logo.png"

    $itemTypes = ($types | ForEach-Object {
        "            <desktop5:ItemType Type=`"$(Escape-Xml $_)`">`r`n" +
        "              <desktop5:Verb Id=`"$($item.id)`" Clsid=`"$clsid`" />`r`n" +
        "            </desktop5:ItemType>"
    }) -join "`r`n"
    $manifest = $template.
        Replace('{{PackageName}}', "CtxMenu.$($item.id)").
        Replace('{{Publisher}}', (Escape-Xml $publisher)).
        Replace('{{PublisherDisplayName}}', (Escape-Xml $publisherDisplay)).
        Replace('{{Version}}', $version).
        Replace('{{Title}}', (Escape-Xml $item.title)).
        Replace('{{Clsid}}', $clsid).
        Replace('{{ItemTypes}}', $itemTypes)
    [IO.File]::WriteAllText("$dir\AppxManifest.xml", $manifest, (New-Object Text.UTF8Encoding $false))

    $layout = Join-Path $ToolsDir "layout-$($item.id)"
    Remove-Item $layout -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory $layout | Out-Null
    Copy-Item "$dir\AppxManifest.xml", "$dir\logo.png" $layout
    $msix = Join-Path $installDir "$($item.id).msix"
    & $makeappx.FullName pack /d $layout /p $msix /nv /o | Out-Null
    if ($LASTEXITCODE) { throw "makeappx failed for $($item.id)" }
    & $signtool sign /fd SHA256 /sha1 $cert.Thumbprint /s My $msix | Out-Null
    if ($LASTEXITCODE) { throw "signtool failed for $($item.id)" }
    Remove-Item $layout -Recurse -Force
    Write-Host "built $msix  ($($item.title), v$version)"
}

if ($changed) { $cfg | ConvertTo-Json -Depth 6 | Set-Content $Config -Encoding UTF8; Write-Host "CLSIDs saved to $Config" }
Write-Host "`nNext: make sure $installDir\ContextMenuBridge.cer is in Local Machine > Trusted People, then run install.ps1 -InstallDir `"$installDir`""
