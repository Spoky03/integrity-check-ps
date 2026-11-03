<#
.SYNOPSIS
    Moduł wspólny projektu „Weryfikacja integralności plików systemowych”.

.DESCRIPTION
    Udostępnia funkcje używane w etapach A/B/C:
    - ładowanie konfiguracji i allowlisty,
    - obliczanie SHA-256,
    - szyfrowanie / odszyfrowanie bazy AES-256,
    - zapis logów do pliku i Event Log,
    - powiadomienia Discord (webhook).

    Politechnika Wrocławska · Cyberbezpieczeństwo
    Stefan Grzelec, Tymoteusz Vogt, Tibor Gałezyka, Bartłomiej Pruszczyk
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-IntegrityProjectRoot {
    <#
    .SYNOPSIS
        Zwraca katalog główny repozytorium (nad src/).
    #>
    # PSScriptRoot dla .psm1 wskazuje na src/ — rodzic to root projektu
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Import-IntegrityConfig {
    <#
    .SYNOPSIS
        Wczytuje hashtable konfiguracji z pliku .psd1.
    .PARAMETER Path
        Ścieżka do paths.psd1; domyślnie config/paths.psd1, fallback do paths.example.psd1.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path
    )

    $root = Get-IntegrityProjectRoot
    if (-not $Path) {
        $local = Join-Path $root 'config\paths.psd1'
        $example = Join-Path $root 'config\paths.example.psd1'
        if (Test-Path -LiteralPath $local) {
            $Path = $local
        }
        else {
            Write-Warning "Brak config/paths.psd1 — używam paths.example.psd1 (skopiuj i uzupełnij webhook/Discord)."
            $Path = $example
        }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Nie znaleziono pliku konfiguracji: $Path"
    }

    # Import-PowerShellDataFile wczytuje .psd1 jako hashtable (bezpieczniej niż Invoke-Expression)
    $cfg = Import-PowerShellDataFile -Path $Path
    $cfg['_ConfigPath'] = (Resolve-Path -LiteralPath $Path).Path
    $cfg['_ProjectRoot'] = $root
    return $cfg
}

function Get-IntegrityVaultPaths {
    <#
    .SYNOPSIS
        Buduje pełne ścieżki artefaktów vaultu na podstawie konfiguracji.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $vault = $Config.VaultRoot
    return [pscustomobject]@{
        VaultRoot     = $vault
        BaselinePath  = Join-Path $vault $Config.BaselineFileName
        KeyPath       = Join-Path $vault $Config.KeyRelativePath
        CopiesRoot    = Join-Path $vault $Config.CopiesRelativePath
        LogsRoot      = Join-Path $vault $Config.LogsRelativePath
        LogFile       = Join-Path (Join-Path $vault $Config.LogsRelativePath) 'integrity.log'
    }
}

function Initialize-IntegrityVault {
    <#
    .SYNOPSIS
        Tworzy strukturę katalogów vaultu (secrets, trusted_copies, logs).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$VaultPaths
    )

    foreach ($dir in @(
            $VaultPaths.VaultRoot,
            (Split-Path -Parent $VaultPaths.KeyPath),
            $VaultPaths.CopiesRoot,
            $VaultPaths.LogsRoot
        )) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Get-IntegrityFileScope {
    <#
    .SYNOPSIS
        Parsuje allowlistę: ścieżka oraz opcjonalna flaga restore (|restore).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    $root = $Config['_ProjectRoot']
    $scopePath = $Config.FileScopePath
    if (-not [System.IO.Path]::IsPathRooted($scopePath)) {
        $scopePath = Join-Path $root $scopePath
    }

    # Fallback na przykład, jeśli lokalny file-scope.txt jeszcze nie istnieje
    if (-not (Test-Path -LiteralPath $scopePath)) {
        $example = Join-Path $root 'config\file-scope.example.txt'
        Write-Warning "Brak $scopePath — używam file-scope.example.txt"
        $scopePath = $example
    }

    $entries = @()
    Get-Content -LiteralPath $scopePath -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }

        $allowRestore = $false
        $pathPart = $line
        if ($line -match '\|restore\s*$') {
            $allowRestore = $true
            $pathPart = ($line -replace '\|restore\s*$', '').Trim()
        }

        $entries += [pscustomobject]@{
            Path         = $pathPart
            AllowRestore = $allowRestore
        }
    }

    return $entries
}

function Get-IntegrityFileRecord {
    <#
    .SYNOPSIS
        Buduje rekord metadanych pliku ze skrótem SHA-256 (Etap A / B).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $false)]
        [bool]$AllowRestore = $false
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $item = Get-Item -LiteralPath $Path -Force
    # Get-FileHash używa .NET Crypto — wynik to 64 znaki hex (SHA-256)
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256

    return [pscustomobject]@{
        Path           = $item.FullName
        Sha256         = $hash.Hash
        Length         = $item.Length
        LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
        AllowRestore   = [bool]$AllowRestore
    }
}

function New-IntegrityAesKey {
    <#
    .SYNOPSIS
        Generuje losowy klucz AES-256 (32 bajty) i zapisuje go do pliku.
    .DESCRIPTION
        Klucz powinien leżeć poza skanowanym systemem (vault na hoście).
        Na produkcji nie trzymaj klucza obok bazy bez dodatkowej ochrony.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    $dir = Split-Path -Parent $KeyPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.GenerateKey()
        [System.IO.File]::WriteAllBytes($KeyPath, $aes.Key)
    }
    finally {
        $aes.Dispose()
    }
}

function Read-IntegrityAesKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    if (-not (Test-Path -LiteralPath $KeyPath)) {
        throw "Brak pliku klucza AES: $KeyPath"
    }

    $bytes = [System.IO.File]::ReadAllBytes($KeyPath)
    if ($bytes.Length -ne 32) {
        throw "Oczekiwano klucza AES-256 (32 bajty), otrzymano $($bytes.Length)."
    }
    return $bytes
}

function Protect-IntegrityBaseline {
    <#
    .SYNOPSIS
        Serializuje rekordy do JSON i szyfruje AES-256-CBC (IV losowy, prefixowany do pliku).
    .DESCRIPTION
        Format pliku .aes: [16 bajtów IV][ciphertext].
        Dzięki temu ten sam plaintext daje inny ciphertext przy każdym zapisie.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Records,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [byte[]]$Key
    )

    $payload = [pscustomobject]@{
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Algorithm  = 'SHA256'
        Records    = @($Records)
    }

    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $Key
        $aes.GenerateIV()

        $encryptor = $aes.CreateEncryptor()
        try {
            $cipher = $encryptor.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
        }
        finally {
            $encryptor.Dispose()
        }

        # IV musi być zapisany razem z ciphertextem — bez niego nie da się odszyfrować
        $combined = New-Object byte[] ($aes.IV.Length + $cipher.Length)
        [Array]::Copy($aes.IV, 0, $combined, 0, $aes.IV.Length)
        [Array]::Copy($cipher, 0, $combined, $aes.IV.Length, $cipher.Length)
        [System.IO.File]::WriteAllBytes($OutputPath, $combined)
    }
    finally {
        $aes.Dispose()
    }
}

function Unprotect-IntegrityBaseline {
    <#
    .SYNOPSIS
        Odszyfrowuje plik baseline.aes i zwraca obiekt z rekordami.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [byte[]]$Key
    )

    if (-not (Test-Path -LiteralPath $InputPath)) {
        throw "Brak zaszyfrowanej bazy: $InputPath"
    }

    $combined = [System.IO.File]::ReadAllBytes($InputPath)
    if ($combined.Length -lt 17) {
        throw "Plik bazy jest uszkodzony lub pusty: $InputPath"
    }

    $iv = New-Object byte[] 16
    $cipherLen = $combined.Length - 16
    $cipher = New-Object byte[] $cipherLen
    [Array]::Copy($combined, 0, $iv, 0, 16)
    [Array]::Copy($combined, 16, $cipher, 0, $cipherLen)

    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = $Key
        $aes.IV = $iv

        $decryptor = $aes.CreateDecryptor()
        try {
            $plainBytes = $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length)
        }
        finally {
            $decryptor.Dispose()
        }
    }
    finally {
        $aes.Dispose()
    }

    $json = [System.Text.Encoding]::UTF8.GetString($plainBytes)
    return ($json | ConvertFrom-Json)
}

function Get-IntegrityTrustedCopyPath {
    <#
    .SYNOPSIS
        Mapuje ścieżkę źródłową na lokalizację w trusted_copies (zachowuje strukturę dysku).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$CopiesRoot
    )

    # C:\Windows\... → C_Windows_... aby uniknąć konfliktów liter dysków
    $full = [System.IO.Path]::GetFullPath($SourcePath)
    $safe = ($full -replace '[:\\\/]', '_').Trim('_')
    return (Join-Path $CopiesRoot $safe)
}

function Save-IntegrityTrustedCopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$CopiesRoot
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        return $null
    }

    $dest = Get-IntegrityTrustedCopyPath -SourcePath $SourcePath -CopiesRoot $CopiesRoot
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
    return $dest
}

function Compare-IntegrityBaseline {
    <#
    .SYNOPSIS
        Porównuje rekordy baseline z bieżącym stanem dysku (Etap B).
    .OUTPUTS
        Obiekty ze Status: OK | Changed | Missing | New
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$BaselineRecords,
        [Parameter(Mandatory = $true)]
        [object[]]$ScopeEntries
    )

    $results = @()
    $baselineByPath = @{}
    foreach ($rec in $BaselineRecords) {
        $baselineByPath[$rec.Path] = $rec
    }

    $scopedPaths = @{}
    foreach ($entry in $ScopeEntries) {
        $scopedPaths[$entry.Path] = $entry
        $expected = $baselineByPath[$entry.Path]

        if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
            # Plik był w bazie lub na allowliście, ale zniknął z dysku
            $results += [pscustomobject]@{
                Path           = $entry.Path
                Status         = 'Missing'
                ExpectedSha256 = if ($expected) { $expected.Sha256 } else { $null }
                ActualSha256   = $null
                AllowRestore   = [bool]$entry.AllowRestore
            }
            continue
        }

        $actual = Get-IntegrityFileRecord -Path $entry.Path -AllowRestore:$entry.AllowRestore
        if (-not $expected) {
            # Nowy plik w allowliście, którego nie było w baseline
            $results += [pscustomobject]@{
                Path           = $entry.Path
                Status         = 'New'
                ExpectedSha256 = $null
                ActualSha256   = $actual.Sha256
                AllowRestore   = [bool]$entry.AllowRestore
            }
            continue
        }

        # Efekt lawinowy SHA-256: dowolna zmiana bajtu zmienia cały skrót
        $status = if ($actual.Sha256 -eq $expected.Sha256) { 'OK' } else { 'Changed' }
        $results += [pscustomobject]@{
            Path           = $entry.Path
            Status         = $status
            ExpectedSha256 = $expected.Sha256
            ActualSha256   = $actual.Sha256
            AllowRestore   = [bool]($expected.AllowRestore -or $entry.AllowRestore)
        }
    }

    # Pliki z baseline usunięte z allowlisty — ignorujemy (świadoma zmiana scope)
    return $results
}

function Write-IntegrityLog {
    <#
    .SYNOPSIS
        Dopisuje linię do pliku logu w vaultcie.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogFile,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $dir = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $line = '{0:o} [{1}] {2}' -f (Get-Date).ToUniversalTime(), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    # Console.Out: widać w SSH/cmd, NIE psuje pipeline (w przeciwieństwie do Write-Host/Write-Output)
    [Console]::Out.WriteLine($line)
}

function Write-IntegrityEventLog {
    <#
    .SYNOPSIS
        Zapisuje wpis do Dziennika zdarzeń Windows (Application / IntegrityCheck).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType = 'Warning',
        [int]$EventId = 4001
    )

    $source = $Config.EventLogSource
    $logName = $Config.EventLogName

    # SourceExists potrafi rzucać bez praw do logu Security — dlatego najpierw Write, potem ewentualnie New-EventLog
    try {
        Write-EventLog -LogName $logName -Source $source -EventId $EventId -EntryType $EntryType -Message $Message
    }
    catch {
        try {
            # Pierwsze uruchomienie jako Administrator rejestruje źródło IntegrityCheck
            New-EventLog -LogName $logName -Source $source -ErrorAction Stop
            Write-EventLog -LogName $logName -Source $source -EventId $EventId -EntryType $EntryType -Message $Message
        }
        catch {
            Write-Warning "Nie udało się zapisać Event Log ($source): $($_.Exception.Message)"
        }
    }
}

function Send-IntegrityDiscordAlert {
    <#
    .SYNOPSIS
        Wysyła powiadomienie na webhook Discord (Etap C).
    .DESCRIPTION
        Używa Invoke-RestMethod (JSON). Pusty / CHANGE_ME webhook = pominięcie wysyłki.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $false)]
        [object[]]$Findings
    )

    $url = $Config.DiscordWebhookUrl
    if (-not $url -or $url -match 'CHANGE_ME') {
        Write-Warning 'DiscordWebhookUrl nieustawiony — pomijam powiadomienie Discord.'
        return $false
    }

    # Discord limit treści ~2000 znaków — skracamy listę znalezisk
    $details = @()
    foreach ($f in @($Findings | Select-Object -First 15)) {
        $details += ('- [{0}] {1}' -f $f.Status, $f.Path)
        if ($f.ExpectedSha256) {
            $details += ('  expected: {0}' -f $f.ExpectedSha256)
        }
        if ($f.ActualSha256) {
            $details += ('  actual:   {0}' -f $f.ActualSha256)
        }
    }

    $bodyText = @"
**IntegrityCheck** na ``$env:COMPUTERNAME``
$Content

$($details -join "`n")
"@

    if ($bodyText.Length -gt 1900) {
        $bodyText = $bodyText.Substring(0, 1900) + "`n…(obcięto)"
    }

    $payload = @{ content = $bodyText } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $url -Method Post -Body $payload -ContentType 'application/json; charset=utf-8' | Out-Null
    return $true
}

function Restore-IntegrityFile {
    <#
    .SYNOPSIS
        Przywraca plik z trusted_copies i weryfikuje SHA-256 względem oczekiwanego.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [Parameter(Mandatory = $true)]
        [string]$CopiesRoot,
        [Parameter(Mandatory = $false)]
        [string]$ExpectedSha256
    )

    $copyPath = Get-IntegrityTrustedCopyPath -SourcePath $TargetPath -CopiesRoot $CopiesRoot
    if (-not (Test-Path -LiteralPath $copyPath -PathType Leaf)) {
        return [pscustomobject]@{
            Success = $false
            Message = "Brak zaufanej kopii: $copyPath"
            Sha256  = $null
        }
    }

    $targetDir = Split-Path -Parent $TargetPath
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $copyPath -Destination $TargetPath -Force
    $hash = (Get-FileHash -LiteralPath $TargetPath -Algorithm SHA256).Hash

    $ok = $true
    $msg = 'Przywrócono plik'
    if ($ExpectedSha256 -and ($hash -ne $ExpectedSha256)) {
        $ok = $false
        $msg = "Przywrócono, ale hash nie zgadza się z baseline (kopia mogła być uszkodzona)."
    }

    return [pscustomobject]@{
        Success = $ok
        Message = $msg
        Sha256  = $hash
    }
}

Export-ModuleMember -Function @(
    'Get-IntegrityProjectRoot',
    'Import-IntegrityConfig',
    'Get-IntegrityVaultPaths',
    'Initialize-IntegrityVault',
    'Get-IntegrityFileScope',
    'Get-IntegrityFileRecord',
    'New-IntegrityAesKey',
    'Read-IntegrityAesKey',
    'Protect-IntegrityBaseline',
    'Unprotect-IntegrityBaseline',
    'Get-IntegrityTrustedCopyPath',
    'Save-IntegrityTrustedCopy',
    'Compare-IntegrityBaseline',
    'Write-IntegrityLog',
    'Write-IntegrityEventLog',
    'Send-IntegrityDiscordAlert',
    'Restore-IntegrityFile'
)
