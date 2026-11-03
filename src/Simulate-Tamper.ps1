<#
.SYNOPSIS
    Bezpieczna symulacja podmiany wielu plików labowych (nie prawdziwy rootkit).

.DESCRIPTION
    Domyślnie modyfikuje:
    - C:\IntegrityDemo\demo-file.txt
    - C:\Windows\Temp\IntegrityCheck-probe.txt
    - C:\Windows\System32\IntegrityCheck-probe.txt (jeśli istnieje)

    To są własne markery labowe w drzewie Windows — skrypt NIE nadpisuje
    notepad.exe / cmd.exe / sterowników.

.PARAMETER Path
    Jedna lub wiele ścieżek. Puste = domyślne cele labowe (istniejące na dysku).

.PARAMETER Mode
    Append | Replace

.PARAMETER Revert
    Przywraca treści z samples\ (demo-file / system-probe).

.PARAMETER EnsureTargets
    Najpierw wywołuje Initialize-LabTargets.ps1 (tworzy brakujące sondy).

.EXAMPLE
    .\Simulate-Tamper.ps1
    .\Simulate-Tamper.ps1 -EnsureTargets
    .\Simulate-Tamper.ps1 -Path 'C:\Windows\Temp\IntegrityCheck-probe.txt','C:\IntegrityDemo\demo-file.txt'
#>

[CmdletBinding()]
param(
    [string[]]$Path,
    [ValidateSet('Append', 'Replace')]
    [string]$Mode = 'Append',
    [switch]$Revert,
    [switch]$EnsureTargets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::Out.WriteLine('=== IntegrityCheck / Simulate-Tamper.ps1 ===')

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$demoOriginal = Get-Content -LiteralPath (Join-Path $projectRoot 'samples\demo-file.txt') -Raw -ErrorAction Stop
$probeOriginal = Get-Content -LiteralPath (Join-Path $projectRoot 'samples\system-probe.txt') -Raw -ErrorAction Stop

if ($EnsureTargets) {
    & (Join-Path $PSScriptRoot 'Initialize-LabTargets.ps1') | Out-Null
}

$defaultCandidates = @(
    'C:\IntegrityDemo\demo-file.txt',
    'C:\Windows\Temp\IntegrityCheck-probe.txt',
    'C:\Windows\System32\IntegrityCheck-probe.txt'
)

if (-not $Path -or $Path.Count -eq 0) {
    $Path = @($defaultCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($Path.Count -eq 0) {
        throw "Brak domyślnych celów. Uruchom .\Initialize-LabTargets.ps1 albo podaj -Path / -EnsureTargets."
    }
}

function Get-OriginalContent {
    param([string]$TargetPath)
    if ($TargetPath -like '*IntegrityCheck-probe.txt') { return $probeOriginal }
    return $demoOriginal
}

$results = @()
foreach ($p in $Path) {
    $dir = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $original = Get-OriginalContent -TargetPath $p

    try {
        if ($Revert) {
            Set-Content -LiteralPath $p -Value $original.TrimEnd("`r", "`n") -Encoding UTF8
            [Console]::Out.WriteLine("Revert: $p")
            $modeLabel = 'Revert'
        }
        elseif ($Mode -eq 'Replace') {
            $tampered = "TAMPERED by Simulate-Tamper.ps1 at $(Get-Date -Format o)`r`nTarget=$p`r`n"
            Set-Content -LiteralPath $p -Value $tampered -Encoding UTF8
            [Console]::Out.WriteLine("Replace: $p")
            $modeLabel = 'Replace'
        }
        else {
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
                Set-Content -LiteralPath $p -Value $original -Encoding UTF8
            }
            # Znacznik z pełną ścieżką — widać na screenie, który plik „systemowy” ruszono
            Add-Content -LiteralPath $p -Value ("TAMPER {0:o} path={1}" -f (Get-Date).ToUniversalTime(), $p) -Encoding UTF8
            [Console]::Out.WriteLine("Append:  $p")
            $modeLabel = 'Append'
        }

        $hash = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
        [Console]::Out.WriteLine("  SHA256=$hash")
        $results += [pscustomobject]@{
            Path   = $p
            Mode   = $modeLabel
            Sha256 = $hash
            Ok     = $true
            Error  = $null
        }
    }
    catch {
        Write-Warning "Nie udało się zmodyfikować ${p}: $($_.Exception.Message)"
        $results += [pscustomobject]@{
            Path   = $p
            Mode   = $Mode
            Sha256 = $null
            Ok     = $false
            Error  = $_.Exception.Message
        }
    }
}

if (@($results | Where-Object Ok).Count -eq 0) {
    throw 'Żaden plik nie został zmodyfikowany.'
}

[Console]::Out.WriteLine('')
[Console]::Out.WriteLine(("Zmodyfikowano {0}/{1} plikow. Uruchom Run-Verify.cmd albo Invoke-Verify.ps1" -f @($results | Where-Object Ok).Count, $results.Count))
$results
