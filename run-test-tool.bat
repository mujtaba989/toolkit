@echo off
title Emirates ID & AEGIS PRO 4 Hardware Diagnostics
echo ========================================================
echo   Emirates ID & AEGIS PRO 4 - Hardware Diagnostic Tool
echo ========================================================
echo.
echo [*] Starting Hardware Bridge on http://127.0.0.1:9005...
echo [*] Launching Diagnostic Suite in your default browser...
echo.

set POWERSHELL_32=%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe

if exist "%POWERSHELL_32%" (
    start "EID Hardware Bridge" /min "%POWERSHELL_32%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-bridge.ps1"
) else (
    start "EID Hardware Bridge" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test-bridge.ps1"
)

timeout /t 2 /nobreak >nul
start http://127.0.0.1:9005/

echo [OK] Diagnostic suite is running!
echo You can keep this window minimized while testing.
echo Press any key to stop the bridge and exit.
pause >nul

taskkill /fi "WINDOWTITLE eq EID Hardware Bridge*" /f >nul 2>&1
exit /b 0
