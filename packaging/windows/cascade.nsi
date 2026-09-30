; Cascade Windows installer (NSIS, Modern UI). Per-user, no administrator rights.
; Built by scripts/package-windows.sh (makensis) from the cross-compiled
; binaries in dist/windows-amd64. Pages: Welcome -> Directory -> Install ->
; Finish (Start Cascade). Registers the browser native-messaging host, adds a
; hidden autostart, an Add/Remove Programs entry and an uninstaller.
Unicode true
!include "MUI2.nsh"
!include "StrFunc.nsh"
!include "WordFunc.nsh"
${StrRep}
!insertmacro VersionCompare

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!define APPNAME "Cascade"
!define HOSTNAME "com.cascade.host"
!define DEVEXTID "kamlaafhjnegfjdbnfajbanjfkemefga"
; Store IDs (from browser/extension/store-ids.env via package-windows.sh).
; When set, browsers install the extension from the store by themselves.
!ifndef CHROME_WEBSTORE_ID
  !define CHROME_WEBSTORE_ID ""
!endif
!ifndef EDGE_ADDONS_ID
  !define EDGE_ADDONS_ID ""
!endif
!define ORIGINS_DEV '"chrome-extension://${DEVEXTID}/"'
!if "${CHROME_WEBSTORE_ID}" != ""
  !define ORIGINS_CHROME '${ORIGINS_DEV}, "chrome-extension://${CHROME_WEBSTORE_ID}/"'
!else
  !define ORIGINS_CHROME '${ORIGINS_DEV}'
!endif
!if "${EDGE_ADDONS_ID}" != ""
  !define ORIGINS_ALL '${ORIGINS_CHROME}, "chrome-extension://${EDGE_ADDONS_ID}/"'
!else
  !define ORIGINS_ALL '${ORIGINS_CHROME}'
!endif

Name "${APPNAME}"
OutFile "..\..\dist\Cascade-Setup-${VERSION}.exe"
InstallDir "$LOCALAPPDATA\Cascade"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ABORTWARNING
!define MUI_ICON "..\..\assets\brand\cascade.ico"
!define MUI_UNICON "..\..\assets\brand\cascade.ico"
!define MUI_WELCOMEPAGE_TEXT "Cascade takes over downloads from your browser: parallel connections, resume, a queue, and a tray app that starts at login.$\r$\n$\r$\nThis installs for the current user only (no administrator rights) and registers the browser integration for Chrome, Chromium, Edge and Brave.$\r$\n$\r$\nOne manual step remains afterwards: loading the Cascade extension in the browser (the final page shows where it is)."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "Cascade is installed"
!if "${CHROME_WEBSTORE_ID}" != ""
!define MUI_FINISHPAGE_TEXT "Last step: restart your browser. It installs the Cascade extension from the store by itself; click Enable when it asks.$\r$\n$\r$\nThen download anything. Cascade asks once how to handle downloads."
!else
!define MUI_FINISHPAGE_TEXT "Last step, in your browser:$\r$\n  1. Open chrome://extensions and turn on Developer mode.$\r$\n  2. Click Load unpacked and choose:$\r$\n     $INSTDIR\extension$\r$\n  3. Download anything. Cascade asks once how to handle downloads.$\r$\n$\r$\nIf the extension's Options page shows a different Extension ID, run:$\r$\n  $INSTDIR\bin\register-extension.cmd <ID>"
!endif
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Start Cascade"
!define MUI_FINISHPAGE_RUN_FUNCTION "LaunchApp"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var AppExe

Function LaunchApp
  Exec '"$AppExe"'
FunctionEnd

; Already installed? Same version: ask to reinstall. Older installed: upgrade
; in place. Newer installed: refuse (downgrades are not supported). Silent
; installs (/S) reinstall or upgrade without asking and still refuse downgrades.
Function .onInit
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayVersion"
  StrCmp $0 "" done
  ${VersionCompare} $0 "${VERSION}" $1   ; 0 equal, 1 installed is newer, 2 installed is older
  StrCmp $1 1 newer
  StrCmp $1 0 same
  Goto done
newer:
  MessageBox MB_ICONSTOP|MB_OK "Cascade $0 is already installed, which is newer than ${VERSION}. Downgrades are not supported.$\r$\n$\r$\nUninstall it from Settings > Apps first if you really want the older version." /SD IDOK
  Abort
same:
  MessageBox MB_ICONQUESTION|MB_YESNO "Cascade ${VERSION} is already installed. Reinstall it? (Settings and downloads are kept.)" /SD IDYES IDYES done
  Abort
done:
FunctionEnd

; Chrome derives an unpacked extension's ID from its folder path; the host
; manifest authorizes the dev ID plus any ID passed to register-extension.cmd.
Function WriteHostManifest
  ; JSON needs backslashes escaped
  ${StrRep} $0 "$INSTDIR\bin\cascade-host.exe" "\" "\\"
  FileOpen $1 "$INSTDIR\bin\${HOSTNAME}.json" w
  FileWrite $1 '{$\r$\n  "name": "${HOSTNAME}",$\r$\n  "description": "Cascade download manager native host",$\r$\n  "path": "$0",$\r$\n  "type": "stdio",$\r$\n  "allowed_origins": [${ORIGINS_ALL}]$\r$\n}$\r$\n'
  FileClose $1
FunctionEnd

; Firefox: fixed add-on ID; its manifest uses allowed_extensions.
Function WriteFirefoxManifest
  ${StrRep} $0 "$INSTDIR\bin\cascade-host.exe" "\" "\\"
  FileOpen $1 "$INSTDIR\bin\${HOSTNAME}.firefox.json" w
  FileWrite $1 '{$\r$\n  "name": "${HOSTNAME}",$\r$\n  "description": "Cascade download manager native host",$\r$\n  "path": "$0",$\r$\n  "type": "stdio",$\r$\n  "allowed_extensions": ["cascade@d3xt3r.dev"]$\r$\n}$\r$\n'
  FileClose $1
FunctionEnd

Section "Cascade" SecMain
  ; Windows will not overwrite a running executable: stop the app first.
  ExecWait 'taskkill /IM cascade_app.exe /F'
  ExecWait 'taskkill /IM cascade-gui.exe /F'   ; UI of installs before 0.4.0
  Sleep 500
  Delete "$INSTDIR\bin\cascade-gui.exe"
  SetOutPath "$INSTDIR\bin"
  File "..\..\dist\windows-amd64\cascade-host.exe"
  File "..\..\dist\windows-amd64\cascade.exe"
  File "..\..\dist\windows-amd64\cascade.dll"
  File "register-extension.cmd"
  File "..\..\browser\extension\store-ids.env"
  ; Flutter UI, built on Windows (scripts\flutter-windows.ps1) and placed in
  ; dist\windows-amd64\cascade_app before packaging.
  SetOutPath "$INSTDIR\bin\cascade_app"
  File /r "..\..\dist\windows-amd64\cascade_app\*.*"
  SetOutPath "$INSTDIR\extension"
  File /r "..\..\browser\extension\*.*"

  StrCpy $AppExe "$INSTDIR\bin\cascade_app\cascade_app.exe"

  Call WriteHostManifest
  Call WriteFirefoxManifest
  WriteRegStr HKCU "Software\Mozilla\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.firefox.json"
  WriteRegStr HKCU "Software\Google\Chrome\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.json"
  WriteRegStr HKCU "Software\Chromium\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.json"
  WriteRegStr HKCU "Software\Microsoft\Edge\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.json"
  WriteRegStr HKCU "Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.json"

  ; Published extension: each browser installs it from its store on next start
  ; (Chrome shows a one-time "Enable extension" prompt).
!if "${CHROME_WEBSTORE_ID}" != ""
  WriteRegStr HKCU "Software\Google\Chrome\Extensions\${CHROME_WEBSTORE_ID}" "update_url" "https://clients2.google.com/service/update2/crx"
  WriteRegStr HKCU "Software\Chromium\Extensions\${CHROME_WEBSTORE_ID}" "update_url" "https://clients2.google.com/service/update2/crx"
  WriteRegStr HKCU "Software\BraveSoftware\Brave-Browser\Extensions\${CHROME_WEBSTORE_ID}" "update_url" "https://clients2.google.com/service/update2/crx"
!endif
!if "${EDGE_ADDONS_ID}" != ""
  WriteRegStr HKCU "Software\Microsoft\Edge\Extensions\${EDGE_ADDONS_ID}" "update_url" "https://edge.microsoft.com/extensionwebstorebase/v1/crx"
!endif

  ; Start at login, hidden (tray icon only)
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APPNAME}" '"$AppExe" --background'

  ; Start menu + Add/Remove Programs + uninstaller
  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\${APPNAME}.lnk" "$AppExe"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Uninstall ${APPNAME}.lnk" "$INSTDIR\Uninstall.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayName" "${APPNAME}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "Publisher" "d3xt3r"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ExecWait 'taskkill /IM cascade_app.exe /F' ; ignore result
  DeleteRegKey HKCU "Software\Google\Chrome\NativeMessagingHosts\${HOSTNAME}"
  DeleteRegKey HKCU "Software\Chromium\NativeMessagingHosts\${HOSTNAME}"
  DeleteRegKey HKCU "Software\Microsoft\Edge\NativeMessagingHosts\${HOSTNAME}"
  DeleteRegKey HKCU "Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\${HOSTNAME}"
  DeleteRegKey HKCU "Software\Mozilla\NativeMessagingHosts\${HOSTNAME}"
!if "${CHROME_WEBSTORE_ID}" != ""
  DeleteRegKey HKCU "Software\Google\Chrome\Extensions\${CHROME_WEBSTORE_ID}"
  DeleteRegKey HKCU "Software\Chromium\Extensions\${CHROME_WEBSTORE_ID}"
  DeleteRegKey HKCU "Software\BraveSoftware\Brave-Browser\Extensions\${CHROME_WEBSTORE_ID}"
!endif
!if "${EDGE_ADDONS_ID}" != ""
  DeleteRegKey HKCU "Software\Microsoft\Edge\Extensions\${EDGE_ADDONS_ID}"
!endif
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APPNAME}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
  Delete "$SMPROGRAMS\${APPNAME}\*.lnk"
  RMDir "$SMPROGRAMS\${APPNAME}"
  RMDir /r "$INSTDIR"
SectionEnd
