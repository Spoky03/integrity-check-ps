<#
.SYNOPSIS
    Etap A — budowa referencyjnej bazy sum SHA-256 i zaufanych kopii.

.DESCRIPTION
    Dla każdego pliku z allowlisty (config/file-scope*.txt):
    1. Oblicza Get-FileHash -Algorithm SHA256
    2. Zapisuje ścieżkę, skrót, rozmiar, datę modyfikacji
    3. Kopiuje plik do trusted_copies w vaultcie (host)
    4. Szyfruje całą bazę AES-256 → baseline.aes

    Wymagania: dostępny vault (np. Z:\IntegrityVault), uprawnienia odczytu plików.

.PARAMETER ConfigPath
    Opcjonalna ścieżka do paths.psd1.

.PARAMETER ForceNewKey
    Wymusza wygenerowanie nowego klucza AES (nadpisuje istniejący).

.EXAMPLE
    .\New-Baseline.ps1
    .\New-Baseline.ps1 -ForceNewKey
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$ForceNewKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::Out.WriteLine('=== IntegrityCheck / Etap A: New-Baseline.ps1 ===')

$modulePath = Join-Path $PSScriptRoot 'IntegrityCheck.psm1'
Import-Module $modulePath -Force

$config = Import-IntegrityConfig -Path $ConfigPath
$vault = Get-IntegrityVaultPaths -Config $config
Initialize-IntegrityVault -VaultPaths $vault

Write-IntegrityLog -LogFile $vault.LogFile -Message 'Start Etap A: budowa baseline' -Level INFO

# Klucz AES poza skanowanym systemem (vault na hoście)
if ($ForceNewKey -or -not (Test-Path -LiteralPath $vault.KeyPath)) {
    Write-IntegrityLog -LogFile $vault.LogFile -Message "Generuję klucz AES-256 → $($vault.KeyPath)" -Level INFO
    New-IntegrityAesKey -KeyPath $vault.KeyPath
}
else {
    Write-IntegrityLog -LogFile $vault.LogFile -Message "Używam istniejącego klucza: $($vault.KeyPath)" -Level INFO
}

$key = Read-IntegrityAesKey -KeyPath $vault.KeyPath
$scope = @(Get-IntegrityFileScope -Config $config)

if ($scope.Count -eq 0) {
    throw 'Allowlista jest pusta — uzupełnij config/file-scope.txt'
}

$records = @()
$skipped = @()

foreach ($entry in $scope) {
    if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
        $skipped += $entry.Path
        Write-IntegrityLog -LogFile $vault.LogFile -Message "Pominięto (brak pliku): $($entry.Path)" -Level WARN
        continue
    }

    $rec = Get-IntegrityFileRecord -Path $entry.Path -AllowRestore:$entry.AllowRestore
    $records += $rec

    # Zaufana kopia potrzebna do Etapu C (przywrócenie)
    $copy = Save-IntegrityTrustedCopy -SourcePath $entry.Path -CopiesRoot $vault.CopiesRoot
    [Console]::Out.WriteLine(("  {0}  SHA256={1}  restore={2}  copy={3}" -f $rec.Path, $rec.Sha256, $rec.AllowRestore, $copy))
}

if ($records.Count -eq 0) {
    throw 'Nie zebrano żadnych rekordów — sprawdź ścieżki w allowliście i dostępność plików.'
}

# Szyfrowanie całej bazy — plaintext nie pozostaje w vaultcie
Protect-IntegrityBaseline -Records $records -OutputPath $vault.BaselinePath -Key $key

Write-IntegrityLog -LogFile $vault.LogFile -Message (
    "Baseline zapisany: $($vault.BaselinePath) (rekordów: $($records.Count), pominiętych: $($skipped.Count))"
) -Level INFO

[Console]::Out.WriteLine('')
[Console]::Out.WriteLine("Etap A zakonczony. Zaszyfrowana baza: $($vault.BaselinePath)")
[Console]::Out.WriteLine("Klucz: $($vault.KeyPath)")
[Console]::Out.WriteLine("Kopie: $($vault.CopiesRoot)")
[Console]::Out.WriteLine(("RecordCount={0}" -f $records.Count))

[pscustomobject]@{
    BaselinePath   = $vault.BaselinePath
    RecordCount    = $records.Count
    SkippedCount   = $skipped.Count
    SkippedPaths   = $skipped
    RecordsPreview = $records
}
