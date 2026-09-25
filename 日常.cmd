@echo off
rem ============================================================
rem  GameCurfew daily menu (launcher only - keep ASCII!)
rem  Chinese UI is printed by gamecurfew.ps1. See install.cmd for why.
rem  This one does NOT request admin: the menu only elevates for
rem  the two actions that actually need it.
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Menu
exit /b