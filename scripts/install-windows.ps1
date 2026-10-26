# Install Spate on Windows: binaries to %LOCALAPPDATA%\Spate\bin, browser
# native-messaging host registration (registry), and autostart at login.
#
#   powershell -ExecutionPolicy Bypass -File install-windows.ps1 [-ExtensionIds id1,id2] [-NoAutostart]
param(
  [string[]]$ExtensionIds = @("kamlaafhjnegfjdbnfajbanjfkemefga"),
  [switch]$NoAutostart
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bin  = Join-Path $env:LOCALAPPDATA "Spate\bin"
New-Item -ItemType Directory -Force -Path $Bin | Out-Null

# Stop and retire the pre-0.4.0 UI so the new app owns the port.
foreach ($p in @("spate_app", "spate-gui")) { Get-Process $p -ErrorAction SilentlyContinue | Stop-Process -Force }
Remove-Item (Join-Path $Bin "spate-gui.exe") -ErrorAction SilentlyContinue
foreach ($f in @("spate-host.exe", "spate.exe", "spate.dll")) {
  $src = Join-Path $Root $f
  if (Test-Path $src) { Copy-Item $src $Bin -Force; Write-Host "    $Bin\$f" }
}
# Flutter Windows bundle, if it was built (flutter-windows.ps1) and shipped alongside.
$bundle = Join-Path $Root "spate_app"
if (Test-Path $bundle) {
  if (Test-Path (Join-Path $Bin "spate_app")) { Remove-Item (Join-Path $Bin "spate_app") -Recurse -Force }
  Copy-Item $bundle (Join-Path $Bin "spate_app") -Recurse -Force
  Write-Host "    $Bin\spate_app\spate_app.exe (Flutter UI)"
}

# Native messaging host manifest + registry keys (per user).
$manifestPath = Join-Path $Bin "com.amlabs.spate.host.json"
$manifest = [ordered]@{
  name            = "com.amlabs.spate.host"
  description     = "Spate download manager native host"
  path            = (Join-Path $Bin "spate-host.exe")
  type            = "stdio"
  allowed_origins = @($ExtensionIds | ForEach-Object { "chrome-extension://$_/" })
} | ConvertTo-Json
Set-Content -Path $manifestPath -Value $manifest -Encoding UTF8
Write-Host "    $manifestPath"

$keys = @(
  "HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.amlabs.spate.host",
  "HKCU:\Software\Chromium\NativeMessagingHosts\com.amlabs.spate.host",
  "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.amlabs.spate.host",
  "HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.amlabs.spate.host"
)
foreach ($k in $keys) {
  New-Item -Path $k -Force | Out-Null
  Set-ItemProperty -Path $k -Name "(Default)" -Value $manifestPath
  Write-Host "    $k"
}

# Autostart (hidden): the Flutter UI.
if (-not $NoAutostart) {
  $app = Join-Path $Bin "spate_app\spate_app.exe"
  if (-not (Test-Path $app)) { Write-Host "    ! spate_app not installed: build it with flutter-windows.ps1 and re-run" }
  Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Spate" -Value "`"$app`" --background"
  Write-Host "    autostart: $app --background"
}

Write-Host "==> done. Load the 'extension' folder in chrome://extensions (Developer mode -> Load unpacked)."
