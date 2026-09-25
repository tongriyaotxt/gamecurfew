@echo off
rem ============================================================
rem  GameCurfew one-click installer (launcher only - keep ASCII!)
rem
rem  WHY NO CHINESE HERE: cmd.exe tracks its position in a batch
rem  file by BYTE OFFSET. Any code-page switch (chcp) or non-ASCII
rem  byte can desync that offset and split lines in half.
rem  So all Chinese UI is printed by gamecurfew.ps1 instead.
rem ============================================================
setlocal
cd /d "%~dp0"
set "PS1=%~dp0gamecurfew.ps1"

if not exist "%PS1%" (
    echo.
    echo   [ERROR] gamecurfew.ps1 was not found in this folder.
    echo           Keep this launcher and gamecurfew.ps1 in the SAME folder.
    echo.
    pause
    exit /b 1
)

for /f %%i in ('powershell -NoProfile -Command "([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)"') do set "ADMIN=%%i"
if /i not "%ADMIN%"=="True" (
    echo.
    echo   Requesting administrator rights. Please click "Yes" in the popup...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem clear the "downloaded from the internet" mark, otherwise PowerShell refuses to run it
powershell -NoProfile -Command "Get-ChildItem '%~dp0*.ps1' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Wizard
if errorlevel 1 (
    echo.
    echo   [FAILED] Something went wrong. Please send me a screenshot.
    echo.
)
pause
exit /b