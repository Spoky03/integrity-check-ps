<#
.SYNOPSIS
    Tworzy pliki labowe do monitorowania (demo + sondy w katalogach Windows).

.DESCRIPTION
    Nie modyfikuje prawdziwych binariów (notepad/cmd). Zakłada własne pliki-markery:
    - C:\IntegrityDemo\demo-file.txt
    - C:\Windows\Temp\IntegrityCheck-probe.txt
    - C:\Windows\System32\IntegrityCheck-probe.txt (wymaga uprawnień zapisu do System32)

    Uruchom PRZED New-Baseline.ps1, potem dopisz ścieżki do file-scope (|restore).

.EXAMPLE
    .\Initialize-LabTargets.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$demoSample = Join-Path $projectRoot 'samples\demo-file.txt'
$probeSample = Join-Path $projectRoot 'samples\system-probe.txt'

$targets = @(
    [pscustomobject]@{ Path = 'C:\IntegrityDemo\demo-file.txt'; Sample = $demoSample; Required = $true }
    [pscustomobject]@{ Path = 'C:\Windows\Temp\IntegrityCheck-probe.txt'; Sample = $probeSample; Required = $true }
    [pscustomobject]@{ Path = 'C:\Windows\System32\IntegrityCheck-probe.txt'; Sample = $probeSample; Required = $false }
)

$created = @()
foreach ($t in $targets) {
    $dir = Split-Path -Parent $t.Path
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Copy-Item -LiteralPath $t.Sample -Destination $t.Path -Force
        $hash = (Get-FileHash -LiteralPath $t.Path -Algorithm SHA256).Hash
        Write-Host "OK  $($t.Path)" -ForegroundColor Green
        Write-Host "    SHA256=$hash"
        $created += [pscustomobject]@{ Path = $t.Path; Ok = $true; Sha256 = $hash; Error = $null }
    }
    catch {
        $msg = $_.Exception.Message
        if ($t.Required) {
            throw "Nie udało się utworzyć wymaganego celu $($t.Path): $msg"
        }
        Write-Warning "Pominięto $($t.Path): $msg (uruchom jako Administrator, żeby mieć sondę w System32)"
        $created += [pscustomobject]@{ Path = $t.Path; Ok = $false; Sha256 = $null; Error = $msg }
    }
}

Write-Host ""
Write-Host "Dodaj do config\file-scope.txt linie z |restore dla utworzonych plików, potem New-Baseline.ps1" -ForegroundColor Cyan
$created
