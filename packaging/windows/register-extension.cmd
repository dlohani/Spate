@echo off
rem Re-register the Cascade browser host with an extra extension ID (shown on
rem the extension's Options page):  register-extension.cmd <ID>
setlocal
set "BIN=%~dp0"
set "BIN=%BIN:~0,-1%"
if "%~1"=="" (
  echo usage: register-extension.cmd EXTENSION_ID
  exit /b 2
)
set "HOSTEXE=%BIN%\cascade-host.exe"
set "HOSTEXE_JSON=%HOSTEXE:\=\\%"
(
  echo {
  echo   "name": "com.cascade.host",
  echo   "description": "Cascade download manager native host",
  echo   "path": "%HOSTEXE_JSON%",
  echo   "type": "stdio",
  echo   "allowed_origins": ["chrome-extension://kamlaafhjnegfjdbnfajbanjfkemefga/", "chrome-extension://%~1/"]
  echo }
) > "%BIN%\com.cascade.host.json"
for %%K in ("Google\Chrome" "Chromium" "Microsoft\Edge" "BraveSoftware\Brave-Browser") do (
  reg add "HKCU\Software\%%~K\NativeMessagingHosts\com.cascade.host" /ve /t REG_SZ /d "%BIN%\com.cascade.host.json" /f >nul
)
echo registered extension ID %~1
endlocal
