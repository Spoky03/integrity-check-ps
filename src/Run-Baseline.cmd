@echo off
REM Launcher pod SSH/cmd — zawsze odpala PowerShell z widocznym stdout
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-Baseline.ps1" %*
echo.
echo ExitCode=%ERRORLEVEL%
