@echo off
rem Runs uninstall.ps1 without changing the system-wide PowerShell execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
