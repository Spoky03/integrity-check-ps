@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-Verify.ps1" %*
echo.
echo ExitCode=%ERRORLEVEL%
