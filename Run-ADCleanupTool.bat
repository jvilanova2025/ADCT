@echo off
title AD Cleanup Tool
rem  ------------------------------------------------------------------
rem  Launcher for adct.ps1 (the AD Cleanup Tool)
rem  - Keep this file in the SAME folder as adct.ps1
rem  - Right-click it and choose "Run as administrator"
rem  - Grants run permission for this window only and pauses at the end
rem    to keep any errors on screen.
rem  ------------------------------------------------------------------
if not exist "%~dp0adct.ps1" (
    echo Could not find adct.ps1 in this folder. Keep both files together.
    echo.
    echo Press any key to close this window.
    pause >nul
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0adct.ps1"
echo.
echo Press any key to close this window.
pause >nul
