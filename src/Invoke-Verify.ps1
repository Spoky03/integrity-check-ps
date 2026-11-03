<#
.SYNOPSIS
    Etap B — cykliczne porównanie bieżących sum SHA-256 z zaszyfrowaną bazą.

.DESCRIPTION
    1. Odszyfrowanie baseline.aes kluczem z vaultu
    2. Przeliczenie bieżących sum dla allowlisty
    3. Porównanie: OK / Changed / Missing / New
    4. Przy rozbieżnościach wywołanie Etapu C (Invoke-Response.ps1), chyba że -SkipResponse

    Przeznaczone do uruchamiania ręcznie lub przez Task Scheduler.

.PARAMETER ConfigPath
    Opcjonalna ścieżka do paths.psd1.

.PARAMETER SkipResponse
    Tylko raport na konsolę / log — bez Discord i restore.

.PARAMETER ReportOnly
    Przekazuje tryb raportu do Etapu C (log + Discord, bez restore).

.EXAMPLE
    .\Invoke-Verify.ps1
    .\Invoke-Verify.ps1 -SkipResponse
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$SkipResponse,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::Out.WriteLine('=== IntegrityCheck / Etap B: Invoke-Verify.ps1 ===')

$modulePath = Join-Path $PSScriptRoot 'IntegrityCheck.psm1'
Import-Module $modulePath -Force

$config = Import-IntegrityConfig -Path $ConfigPath
$vault = Get-IntegrityVaultPaths -Config $config
Initialize-IntegrityVault -VaultPaths $vault

Write-IntegrityLog -LogFile $vault.LogFile -Message 'Start Etap B: weryfikacja integralności' -Level INFO

if (-not (Test-Path -LiteralPath $vault.BaselinePath)) {
    throw "Brak bazy baseline: $($vault.BaselinePath). Uruchom najpierw New-Baseline.ps1."
}

$key = Read-IntegrityAesKey -KeyPath $vault.KeyPath

# Odszyfrowanie bazy referencyjnej przechowywanej poza skanowanym systemem
$baseline = Unprotect-IntegrityBaseline -InputPath $vault.BaselinePath -Key $key
$records = @($baseline.Records)
$scope = @(Get-IntegrityFileScope -Config $config)

$results = @(Compare-IntegrityBaseline -BaselineRecords $records -ScopeEntries $scope)

$ok = @($results | Where-Object { $_.Status -eq 'OK' })
$bad = @($results | Where-Object { $_.Status -ne 'OK' })

[Console]::Out.WriteLine('')
[Console]::Out.WriteLine(("Wynik weryfikacji: OK={0}  rozbieznosci={1}" -f $ok.Count, $bad.Count))
# Tabela na konsolę (nie do pipeline)
[Console]::Out.WriteLine(($results | Format-Table -AutoSize Path, Status, ExpectedSha256, ActualSha256 | Out-String))

Write-IntegrityLog -LogFile $vault.LogFile -Message (
    "Weryfikacja zakończona: OK=$($ok.Count), bad=$($bad.Count)"
) -Level $(if ($bad.Count) { 'WARN' } else { 'INFO' })

$response = $null
if ($bad.Count -gt 0 -and -not $SkipResponse) {
    $responseScript = Join-Path $PSScriptRoot 'Invoke-Response.ps1'
    $responseParams = @{
        Findings = $bad
    }
    if ($ConfigPath) { $responseParams['ConfigPath'] = $ConfigPath }
    if ($ReportOnly) { $responseParams['ReportOnly'] = $true }

    # Etap C: log, Discord, ewentualne przywrócenie
    $response = & $responseScript @responseParams
}
elseif ($bad.Count -gt 0 -and $SkipResponse) {
    Write-IntegrityLog -LogFile $vault.LogFile -Message 'SkipResponse: pominięto Etap C' -Level INFO
}

# Kod wyjścia: 0 = czysto, 2 = są rozbieżności (wygodne dla Task Scheduler / CI)
$exitCode = if ($bad.Count -gt 0) { 2 } else { 0 }

$resultObj = [pscustomobject]@{
    OkCount       = $ok.Count
    FindingCount  = $bad.Count
    Results       = $results
    Response      = $response
    ExitCode      = $exitCode
}

# Gdy uruchamiane interaktywnie — ustaw exit; przy dot-source nie zamykaj hosta agresywnie
if ($MyInvocation.InvocationName -ne '.') {
    $global:LASTEXITCODE = $exitCode
}

return $resultObj
