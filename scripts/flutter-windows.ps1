# Build the Flutter Windows UI with the Go core (cascade.dll) next to it.
# Run ON Windows with Flutter + Visual Studio (Desktop development with C++).
#
#   powershell -ExecutionPolicy Bypass -File scripts\flutter-windows.ps1
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dll  = Join-Path $Root "dist\windows-amd64\cascade.dll"
if (-not (Test-Path $Dll)) {
  Write-Host "building cascade.dll natively (needs Go + a C compiler such as MSYS2/mingw-w64 gcc)"
  New-Item -ItemType Directory -Force -Path (Split-Path $Dll) | Out-Null
  $env:CGO_ENABLED = "1"
  & go build -buildmode=c-shared -o $Dll (Join-Path $Root "export\cshared")
}
Push-Location (Join-Path $Root "apps\flutter")
& flutter build windows --release
$bundle = Join-Path (Get-Location) "build\windows\x64\runner\Release"
Copy-Item $Dll (Join-Path $bundle "cascade.dll") -Force   # the Dart loader looks next to the exe
Pop-Location
Write-Host "==> app: $bundle\cascade_app.exe"
Write-Host "    copy that folder next to install-windows.ps1 as 'cascade_app' to install it."
