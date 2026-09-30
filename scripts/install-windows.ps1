# Install Cascade on Windows: binaries to %LOCALAPPDATA%\Cascade\bin, browser
# native-messaging host registration (registry), and autostart at login.
#
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1 [-ExtensionIds id1,id2] [-NoAutostart]
param(
  [string[]]$ExtensionIds = @("kamlaafhjnegfjdbnfajbanjfkemefga"),
  [switch]$NoAutostart
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bin  = Join-Path $env:LOCALAPPDATA "Cascade\bin"
New-Item -ItemType Directory -Force -Path $Bin | Out-Null

foreach ($f in @("cascade-host.exe", "cascade.exe", "cascade.dll")) {
  $src = Join-Path $Root $f
  if (Test-Path $src) { Copy-Item $src $Bin -Force; Write-Host "    $Bin\$f" }
}
# Flutter Windows bundle, if it was built (flutter-windows.ps1) and shipped alongside.
$bundle = Join-Path $Root "cascade_app"
if (Test-Path $bundle) {
  if (Test-Path (Join-Path $Bin "cascade_app")) { Remove-Item (Join-Path $Bin "cascade_app") -Recurse -Force }
  Copy-Item $bundle (Join-Path $Bin "cascade_app") -Recurse -Force
  Write-Host "    $Bin\cascade_app\cascade_app.exe (Flutter UI)"
}

# Native messaging host manifest + registry keys (per user).
$manifestPath = Join-Path $Bin "com.cascade.host.json"
$manifest = [ordered]@{
  name            = "com.cascade.host"
  description     = "Cascade download manager native host"
  path            = (Join-Path $Bin "cascade-host.exe")
  type            = "stdio"
  allowed_origins = @($ExtensionIds | ForEach-Object { "chrome-extension://$_/" })
} | ConvertTo-Json
Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8
Write-Host "    $manifestPath"

$keys = @(
  "HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.cascade.host",
  "HKCU:\Software\Chromium\NativeMessagingHosts\com.cascade.host",
  "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.cascade.host",
  "HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.cascade.host"
)
foreach ($k in $keys) {
  New-Item -Path $k -Force | Out-Null
  Set-ItemProperty -Path $k -Name "(Default)" -Value $manifestPath
  Write-Host "    $k"
}

# Autostart (hidden): the Flutter UI.
if (-not $NoAutostart) {
  $app = Join-Path $Bin "cascade_app\cascade_app.exe"
  if (-not (Test-Path $app)) { Write-Host "    ! cascade_app not installed: build it with flutter-windows.ps1 and re-run" }
  Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Cascade" -Value "`"$app`" --background"
  Write-Host "    autostart: $app --background"
}

Write-Host "==> done. Load the 'extension' folder in chrome://extensions (Developer mode -> Load unpacked)."
