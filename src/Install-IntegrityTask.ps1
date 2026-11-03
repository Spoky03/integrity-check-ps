<#
.SYNOPSIS
    Rejestruje cykliczne zadanie Task Scheduler uruchamiające Invoke-Verify.ps1.

.DESCRIPTION
    Tworzy zadanie „IntegrityCheck-Verify” (domyślnie co 30 minut) z pełną ścieżką
    do skryptu weryfikacji. Wymaga uprawnień administratora.

.PARAMETER IntervalMinutes
    Interwał uruchomienia (domyślnie 30).

.PARAMETER ConfigPath
    Opcjonalna ścieżka do paths.psd1 przekazywana do Invoke-Verify.ps1.

.PARAMETER TaskName
    Nazwa zadania w Harmonogramie.

.PARAMETER Uninstall
    Usuwa zadanie zamiast je tworzyć.

.EXAMPLE
    .\Install-IntegrityTask.ps1
    .\Install-IntegrityTask.ps1 -IntervalMinutes 15
    .\Install-IntegrityTask.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [int]$IntervalMinutes = 30,
    [string]$ConfigPath,
    [string]$TaskName = 'IntegrityCheck-Verify',
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Usunięto zadanie: $TaskName" -ForegroundColor Green
    return
}

$verifyScript = (Resolve-Path (Join-Path $PSScriptRoot 'Invoke-Verify.ps1')).Path

# powershell.exe -NoProfile -ExecutionPolicy Bypass — niezawodne w kontekście SYSTEM/Administrator
$argList = "-NoProfile -ExecutionPolicy Bypass -File `"$verifyScript`""
if ($ConfigPath) {
    $resolvedCfg = (Resolve-Path -LiteralPath $ConfigPath).Path
    $argList += " -ConfigPath `"$resolvedCfg`""
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argList
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

# Najwyższe uprawnienia — odczyt plików systemowych + Event Log
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

Write-Host "Zarejestrowano zadanie '$TaskName' co $IntervalMinutes min." -ForegroundColor Green
Write-Host "Akcja: powershell.exe $argList"
Get-ScheduledTask -TaskName $TaskName | Format-List TaskName, State | Out-Host
