<#
.SYNOPSIS
    Etap C — reakcja na wykryte rozbieżności integralności.

.DESCRIPTION
    Dla listy znalezisk (Changed / Missing / New):
    1. Log ostrzegawczy (plik w vaultcie + Windows Event Log)
    2. Powiadomienie Discord (webhook)
    3. Opcjonalne przywrócenie z trusted_copies — tylko gdy AllowRestore=$true
       i AutoRestore włączone; pliki systemowe Windows domyślnie tylko raportowane.

    Zwykle wywoływane z Invoke-Verify.ps1; można też podać -FindingsJson.

.PARAMETER ConfigPath
    Opcjonalna ścieżka do paths.psd1.

.PARAMETER Findings
    Tablica obiektów wyniku porównania (ze Status ≠ OK).

.PARAMETER FindingsJson
    Alternatywnie: JSON ze znaleziskami (do wywołań zewnętrznych).

.PARAMETER ReportOnly
    Wymusza tryb bez restore (nadpisuje config).

.EXAMPLE
    .\Invoke-Response.ps1 -Findings $bad
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [Parameter(Mandatory = $false)]
    [object[]]$Findings,
    [string]$FindingsJson,
    [switch]$ReportOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'IntegrityCheck.psm1'
Import-Module $modulePath -Force

$config = Import-IntegrityConfig -Path $ConfigPath
$vault = Get-IntegrityVaultPaths -Config $config
Initialize-IntegrityVault -VaultPaths $vault

if ($FindingsJson) {
    $Findings = @($FindingsJson | ConvertFrom-Json)
}

$Findings = @($Findings | Where-Object { $_ -and $_.Status -ne 'OK' })
if ($Findings.Count -eq 0) {
    Write-IntegrityLog -LogFile $vault.LogFile -Message 'Etap C: brak rozbieżności — nic do zrobienia' -Level INFO
    return [pscustomobject]@{ Alerted = $false; Restored = @(); Findings = @() }
}

$reportOnly = $ReportOnly -or [bool]$config.ReportOnly
$autoRestore = [bool]$config.AutoRestore -and -not $reportOnly

# --- 1. Log ostrzegawczy ---
$summaryLines = @(
    "Wykryto $($Findings.Count) rozbieżności integralności na $env:COMPUTERNAME"
)
foreach ($f in $Findings) {
    $summaryLines += "[{0}] {1}" -f $f.Status, $f.Path
    if ($f.ExpectedSha256) { $summaryLines += "  expected SHA-256: $($f.ExpectedSha256)" }
    if ($f.ActualSha256) { $summaryLines += "  actual   SHA-256: $($f.ActualSha256)" }
}
$summary = $summaryLines -join [Environment]::NewLine

Write-IntegrityLog -LogFile $vault.LogFile -Message $summary.Replace([Environment]::NewLine, ' | ') -Level WARN
Write-IntegrityEventLog -Config $config -Message $summary -EntryType Warning -EventId 4001

# --- 2. Powiadomienie Discord ---
$discordOk = Send-IntegrityDiscordAlert -Config $config -Content $summaryLines[0] -Findings $Findings
Write-IntegrityLog -LogFile $vault.LogFile -Message ("Discord wysłany: {0}" -f $discordOk) -Level INFO

# --- 3. Przywrócenie kopii (tylko allowlista z |restore) ---
$restored = @()
if ($autoRestore) {
    foreach ($f in $Findings) {
        # Bezpieczeństwo: nie przywracamy automatycznie binariów systemowych bez flagi
        if (-not $f.AllowRestore) {
            Write-IntegrityLog -LogFile $vault.LogFile -Message "Skip restore (brak AllowRestore): $($f.Path)" -Level INFO
            continue
        }
        if ($f.Status -eq 'New') {
            Write-IntegrityLog -LogFile $vault.LogFile -Message "Skip restore (Status=New): $($f.Path)" -Level INFO
            continue
        }

        $result = Restore-IntegrityFile -TargetPath $f.Path -CopiesRoot $vault.CopiesRoot -ExpectedSha256 $f.ExpectedSha256
        $restored += [pscustomobject]@{
            Path    = $f.Path
            Success = $result.Success
            Message = $result.Message
            Sha256  = $result.Sha256
        }
        $lvl = if ($result.Success) { 'INFO' } else { 'ERROR' }
        Write-IntegrityLog -LogFile $vault.LogFile -Message ("Restore {0}: {1}" -f $f.Path, $result.Message) -Level $lvl
    }
}
else {
    Write-IntegrityLog -LogFile $vault.LogFile -Message 'Tryb ReportOnly / AutoRestore=false — bez przywracania plików' -Level INFO
}

[pscustomobject]@{
    Alerted   = $true
    Discord   = $discordOk
    Restored  = $restored
    Findings  = $Findings
    ReportOnly = $reportOnly
}
