<#
.SYNOPSIS
    Test dymny pipeline A→B→C z wieloma celami (demo + „systemowa” sonda).

.DESCRIPTION
    Symuluje drugi plik w ścieżce typu Windows\Temp (lokalnie pod .vault\smoke),
    tamperuje OBA pliki, oczekuje 2× Changed + restore obu.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$src = Join-Path $root 'src'
$work = Join-Path $root '.vault\smoke'
$demoDir = Join-Path $work 'demo'
$winTemp = Join-Path $work 'Windows\Temp'
$demoFile = Join-Path $demoDir 'demo-file.txt'
$probeFile = Join-Path $winTemp 'IntegrityCheck-probe.txt'
$cfgDir = Join-Path $work 'config'
$vaultRoot = Join-Path $work 'IntegrityVault'

Write-Host "=== smoke-test IntegrityCheck (multi-target) ===" -ForegroundColor Cyan
Write-Host "Work: $work"

if (Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
}
New-Item -ItemType Directory -Path $demoDir, $winTemp, $cfgDir, $vaultRoot -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $root 'samples\demo-file.txt') -Destination $demoFile -Force
Copy-Item -LiteralPath (Join-Path $root 'samples\system-probe.txt') -Destination $probeFile -Force

$scopePath = Join-Path $cfgDir 'file-scope.txt'
@(
    '# smoke scope — demo + sonda „systemowa”'
    "$demoFile|restore"
    "$probeFile|restore"
) | Set-Content -LiteralPath $scopePath -Encoding UTF8

$cfgPath = Join-Path $cfgDir 'paths.psd1'
@(
    '@{'
    "    VaultRoot          = '$vaultRoot'"
    "    BaselineFileName   = 'baseline.aes'"
    "    KeyRelativePath    = 'secrets\aes.key'"
    "    CopiesRelativePath = 'trusted_copies'"
    "    LogsRelativePath   = 'logs'"
    "    EventLogSource     = 'IntegrityCheck'"
    "    EventLogName       = 'Application'"
    "    DiscordWebhookUrl  = 'https://discord.com/api/webhooks/CHANGE_ME/CHANGE_ME'"
    "    FileScopePath      = '$scopePath'"
    '    AutoRestore        = $true'
    '    ReportOnly         = $false'
    '}'
) | Set-Content -LiteralPath $cfgPath -Encoding UTF8

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAIL: $Message" }
    Write-Host "OK: $Message" -ForegroundColor Green
}

$baseline = & (Join-Path $src 'New-Baseline.ps1') -ConfigPath $cfgPath -ForceNewKey
Assert-True ($baseline.RecordCount -eq 2) "Baseline ma 2 rekordy"

$v1 = & (Join-Path $src 'Invoke-Verify.ps1') -ConfigPath $cfgPath -SkipResponse
Assert-True ($v1.FindingCount -eq 0) "Pierwsza weryfikacja bez rozbieżności"

# Tamper obu celów naraz
& (Join-Path $src 'Simulate-Tamper.ps1') -Path @($demoFile, $probeFile) -Mode Append | Out-Null

$v2 = & (Join-Path $src 'Invoke-Verify.ps1') -ConfigPath $cfgPath
Assert-True ($v2.FindingCount -eq 2) "Wykryto 2 rozbieżności po tamper"
$changed = @($v2.Results | Where-Object { $_.Status -eq 'Changed' })
Assert-True ($changed.Count -eq 2) "Oba pliki Status=Changed"
Assert-True ($null -ne $v2.Response) "Wywołano Response"
$restoredOk = @($v2.Response.Restored | Where-Object { $_.Success })
Assert-True ($restoredOk.Count -eq 2) "Restore obu plików OK"

$v3 = & (Join-Path $src 'Invoke-Verify.ps1') -ConfigPath $cfgPath -SkipResponse
Assert-True ($v3.FindingCount -eq 0) "Po restore ponownie OK"

Write-Host ""
Write-Host "smoke-test PASSED" -ForegroundColor Green
