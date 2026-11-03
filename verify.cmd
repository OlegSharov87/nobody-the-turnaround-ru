@echo off
rem Runs verify.ps1 without changing the system-wide PowerShell execution policy.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify.ps1" %*
echo.
pause
