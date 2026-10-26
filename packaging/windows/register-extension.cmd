@echo off
rem Re-register the Spate browser host, optionally with an extra extension ID
rem (shown on the extension's Options page):  register-extension.cmd [ID]
rem Also registers the store-published extension (IDs in store-ids.env) with
rem the browsers so they install it by themselves.
setlocal EnableDelayedExpansion
set "BIN=%~dp0"
set "BIN=%BIN:~0,-1%"
set "CHROME_WEBSTORE_ID="
set "EDGE_ADDONS_ID="
if exist "%BIN%\store-ids.env" for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%BIN%\store-ids.env") do set "%%A=%%B"
set "ORIGINS="chrome-extension://kamlaafhjnegfjdbnfajbanjfkemefga/""
if not "%CHROME_WEBSTORE_ID%"=="" set "ORIGINS=!ORIGINS!, "chrome-extension://%CHROME_WEBSTORE_ID%/""
if not "%EDGE_ADDONS_ID%"=="" set "ORIGINS=!ORIGINS!, "chrome-extension://%EDGE_ADDONS_ID%/""
if not "%~1"=="" set "ORIGINS=!ORIGINS!, "chrome-extension://%~1/""
set "HOSTEXE=%BIN%\spate-host.exe"
set "HOSTEXE_JSON=%HOSTEXE:\=\\%"
(
  echo {
  echo   "name": "com.amlabs.spate.host",
  echo   "description": "Spate download manager native host",
  echo   "path": "%HOSTEXE_JSON%",
  echo   "type": "stdio",
  echo   "allowed_origins": [!ORIGINS!]
  echo }
) > "%BIN%\com.amlabs.spate.host.json"
for %%K in ("Google\Chrome" "Chromium" "Microsoft\Edge" "BraveSoftware\Brave-Browser") do (
  reg add "HKCU\Software\%%~K\NativeMessagingHosts\com.amlabs.spate.host" /ve /t REG_SZ /d "%BIN%\com.amlabs.spate.host.json" /f >nul
)
rem Firefox: fixed add-on ID, manifest keyed by allowed_extensions.
(
  echo {
  echo   "name": "com.amlabs.spate.host",
  echo   "description": "Spate download manager native host",
  echo   "path": "%HOSTEXE_JSON%",
  echo   "type": "stdio",
  echo   "allowed_extensions": ["spate@amlabs.dev"]
  echo }
) > "%BIN%\com.amlabs.spate.host.firefox.json"
reg add "HKCU\Software\Mozilla\NativeMessagingHosts\com.amlabs.spate.host" /ve /t REG_SZ /d "%BIN%\com.amlabs.spate.host.firefox.json" /f >nul
if not "%CHROME_WEBSTORE_ID%"=="" (
  for %%K in ("Google\Chrome" "Chromium" "BraveSoftware\Brave-Browser") do (
    reg add "HKCU\Software\%%~K\Extensions\%CHROME_WEBSTORE_ID%" /v update_url /t REG_SZ /d "https://clients2.google.com/service/update2/crx" /f >nul
  )
  echo extension registered: Chrome/Chromium/Brave install it from the store on next start
)
if not "%EDGE_ADDONS_ID%"=="" (
  reg add "HKCU\Software\Microsoft\Edge\Extensions\%EDGE_ADDONS_ID%" /v update_url /t REG_SZ /d "https://edge.microsoft.com/extensionwebstorebase/v1/crx" /f >nul
  echo extension registered: Edge installs it from the store on next start
)
echo host manifest written: %BIN%\com.amlabs.spate.host.json
endlocal
