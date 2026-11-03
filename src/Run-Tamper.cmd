@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Simulate-Tamper.ps1" %*
echo.
echo ExitCode=%ERRORLEVEL%
