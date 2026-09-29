; Cascade Windows installer (NSIS, Modern UI). Per-user, no administrator rights.
; Built by scripts/package-windows.sh (makensis) from the cross-compiled
; binaries in dist/windows-amd64. Pages: Welcome -> Directory -> Install ->
; Finish (Start Cascade). Registers the browser native-messaging host, adds a
; hidden autostart, an Add/Remove Programs entry and an uninstaller.
Unicode true
!include "MUI2.nsh"
!include "StrFunc.nsh"
${StrRep}

!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!define APPNAME "Cascade"
!define HOSTNAME "com.cascade.host"
!define DEVEXTID "kamlaafhjnegfjdbnfajbanjfkemefga"

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
!define MUI_FINISHPAGE_TEXT "Last step, in your browser:$\r$\n  1. Open chrome://extensions and turn on Developer mode.$\r$\n  2. Click Load unpacked and choose:$\r$\n     $INSTDIR\extension$\r$\n  3. Download anything. Cascade asks once how to handle downloads.$\r$\n$\r$\nIf the extension's Options page shows a different Extension ID, run:$\r$\n  $INSTDIR\bin\register-extension.cmd <ID>"
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

; Chrome derives an unpacked extension's ID from its folder path; the host
; manifest authorizes the dev ID plus any ID passed to register-extension.cmd.
Function WriteHostManifest
  ; JSON needs backslashes escaped
  ${StrRep} $0 "$INSTDIR\bin\cascade-host.exe" "\" "\\"
  FileOpen $1 "$INSTDIR\bin\${HOSTNAME}.json" w
  FileWrite $1 '{$\r$\n  "name": "${HOSTNAME}",$\r$\n  "description": "Cascade download manager native host",$\r$\n  "path": "$0",$\r$\n  "type": "stdio",$\r$\n  "allowed_origins": ["chrome-extension://${DEVEXTID}/"]$\r$\n}$\r$\n'
  FileClose $1
FunctionEnd

Section "Cascade" SecMain
  SetOutPath "$INSTDIR\bin"
  File "..\..\dist\windows-amd64\cascade-gui.exe"
  File "..\..\dist\windows-amd64\cascade-host.exe"
  File "..\..\dist\windows-amd64\cascade.exe"
  File "..\..\dist\windows-amd64\cascade.dll"
  File "register-extension.cmd"
  ; Flutter UI, when it was built and placed in dist\windows-amd64\cascade_app
  SetOutPath "$INSTDIR\bin\cascade_app"
  File /nonfatal /r "..\..\dist\windows-amd64\cascade_app\*.*"
  SetOutPath "$INSTDIR\extension"
  File /r "..\..\browser\extension\*.*"

  StrCpy $AppExe "$INSTDIR\bin\cascade-gui.exe"
  IfFileExists "$INSTDIR\bin\cascade_app\cascade_app.exe" 0 +2
    StrCpy $AppExe "$INSTDIR\bin\cascade_app\cascade_app.exe"

  Call WriteHostManifest
  WriteRegStr HKCU "Software\Google\Chrome\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.json"
  WriteRegStr HKCU "Software\Chromium\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.json"
  WriteRegStr HKCU "Software\Microsoft\Edge\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.json"
  WriteRegStr HKCU "Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\${HOSTNAME}" "" "$INSTDIR\bin\${HOSTNAME}.json"

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
  ExecWait 'taskkill /IM cascade-gui.exe /F' ; ignore result
  ExecWait 'taskkill /IM cascade_app.exe /F'
  DeleteRegKey HKCU "Software\Google\Chrome\NativeMessagingHosts\${HOSTNAME}"
  DeleteRegKey HKCU "Software\Chromium\NativeMessagingHosts\${HOSTNAME}"
  DeleteRegKey HKCU "Software\Microsoft\Edge\NativeMessagingHosts\${HOSTNAME}"
  DeleteRegKey HKCU "Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\${HOSTNAME}"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${APPNAME}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
  Delete "$SMPROGRAMS\${APPNAME}\*.lnk"
  RMDir "$SMPROGRAMS\${APPNAME}"
  RMDir /r "$INSTDIR"
SectionEnd
