# Build the Flutter Windows UI with the Go core (spate.dll) next to it.
# Run ON Windows with Flutter + Visual Studio (Desktop development with C++).
#
#   powershell -ExecutionPolicy Bypass -File scripts\flutter-windows.ps1 [-CopyTo <repo on the Mac>]
#
# -CopyTo copies the built bundle to <repo>\dist\windows-amd64\spate_app so
# `./build windows` on the Mac can package the installer, e.g. through the
# Parallels shared folder: -CopyTo \\Mac\Home\Projects\spate
param([string]$CopyTo = "")
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dll  = Join-Path $Root "dist\windows-amd64\spate.dll"
if (-not (Test-Path $Dll)) {
  # The core must match this checkout: prefer the DLL the Mac just
  # cross-compiled (./build windows) in the -CopyTo repo, then an installed
  # one (may be older!), else build it natively.
  $fromMac = if ($CopyTo -ne "") { Join-Path $CopyTo "dist\windows-amd64\spate.dll" } else { "" }
  $installed = Join-Path $env:LOCALAPPDATA "Spate\bin\spate.dll"
  New-Item -ItemType Directory -Force -Path (Split-Path $Dll) | Out-Null
  if ($fromMac -ne "" -and (Test-Path $fromMac)) {
    Copy-Item $fromMac $Dll -Force
    Write-Host "using spate.dll built on the Mac: $fromMac"
  } elseif (Test-Path $installed) {
    Copy-Item $installed $Dll -Force
    Write-Host "using installed spate.dll from $installed"
  } else {
    Write-Host "building spate.dll natively (needs Go + a C compiler such as MSYS2/mingw-w64 gcc)"
    $env:CGO_ENABLED = "1"
    & go build -buildmode=c-shared -o $Dll (Join-Path $Root "export\cshared")
  }
}
Push-Location (Join-Path $Root "apps\flutter")
# Stamp the exe from the VERSION file (product/file version).
$Version = (Get-Content (Join-Path $Root "VERSION") -Raw).Trim()
# SPATE_OBFUSCATE=1 (exactly "1"): rename Dart identifiers. The symbol map is
# a build secret and stays outside the bundle, under dist\debug-symbols.
$obfArgs = @()
if ($env:SPATE_OBFUSCATE -eq "1") {
  $symDir = Join-Path $Root "dist\debug-symbols\windows-$Version"
  New-Item -ItemType Directory -Force -Path $symDir | Out-Null
  $obfArgs = @("--obfuscate", "--split-debug-info=$symDir")
  Write-Host "==> Dart obfuscation on; symbol maps: $symDir"
}
& flutter build windows --release --build-name=$Version --build-number=1 @obfArgs
# Stop here on a failed build: $ErrorActionPreference does not see native exit codes.
if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Host "error: flutter build windows failed (exit $LASTEXITCODE); nothing copied"; exit 1 }
$bundle = Join-Path (Get-Location) "build\windows\x64\runner\Release"
Copy-Item $Dll (Join-Path $bundle "spate.dll") -Force   # the Dart loader looks next to the exe
Pop-Location
Write-Host "==> app: $bundle\spate_app.exe"
if ($CopyTo -ne "") {
  $dest = Join-Path $CopyTo "dist\windows-amd64\spate_app"
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Copy-Item (Join-Path $bundle "*") $dest -Recurse -Force
  Write-Host "==> copied to $dest  (now: ./build windows on the Mac)"
} else {
  Write-Host "    install here: copy that folder next to install-windows.ps1 as 'spate_app', or"
  Write-Host "    hand it to the Mac for packaging: -CopyTo \\Mac\Home\Projects\spate"
}
