# Weryfikacja integralności plików systemowych

Modułowe skrypty **PowerShell** budujące zaszyfrowaną bazę sum **SHA-256**, cyklicznie porównujące pliki z baseline i reagujące na rozbieżności (Event Log, plik logu, **Discord**, kontrolowane przywrócenie).

Projekt studencki — Politechnika Wrocławska · Cyberbezpieczeństwo  
Stefan Grzelec · Tymoteusz Vogt · Tibor Gałezyka · Bartłomiej Pruszczyk

## Etapy (mapowanie na prezentację)

| Etap | Skrypt | Opis |
|------|--------|------|
| A | `src/New-Baseline.ps1` | Allowlista → SHA-256 → AES-256 (`baseline.aes`) + `trusted_copies` |
| B | `src/Invoke-Verify.ps1` | Odszyfrowanie, porównanie (OK / Changed / Missing / New) |
| C | `src/Invoke-Response.ps1` | Log, Discord, restore tylko dla plików z `\|restore` |

## Wymagania

- Windows 10/11 (lab: VM Win10)
- PowerShell 5.1+
- Vault **poza** skanowanym systemem: shared folder hosta (np. `Z:\IntegrityVault`)
- Opcjonalnie: uprawnienia administratora (Event Log source, Task Scheduler, odczyt niektórych plików systemowych)

## Szybki start (lab)

```powershell
# 1) Konfiguracja lokalna (nie commitować sekretów)
Copy-Item config\paths.example.psd1 config\paths.psd1
Copy-Item config\file-scope.example.txt config\file-scope.txt
# Edytuj paths.psd1: VaultRoot, DiscordWebhookUrl
# Edytuj file-scope.txt: ścieżki + |restore przy pliku demo

# 2) Cele labowe: demo + sondy w Windows\Temp i (opcjonalnie) System32
cd src
.\Initialize-LabTargets.ps1
# Upewnij się, że file-scope.txt ma linie |restore dla utworzonych sond

# 3) Baseline → weryfikacja → podmiana WIELU plików → detekcja
.\New-Baseline.ps1
.\Invoke-Verify.ps1
.\Simulate-Tamper.ps1          # demo + Temp (+ System32 jeśli istnieje)
.\Invoke-Verify.ps1
```


Test bez VM / Discord (lokalny vault w `.vault\smoke`):

```powershell
.\tests\smoke-test.ps1
```

## Deploy przez SSH (host → Win10)

Port przekierowany hosta: **2244** (w gościu OpenSSH na 22).

```powershell
scp -P 2244 -r src config samples user@127.0.0.1:C:/IntegrityCheck/
ssh -p 2244 user@127.0.0.1
```

## Harmonogram

```powershell
# Jako Administrator
.\src\Install-IntegrityTask.ps1 -IntervalMinutes 30
.\src\Install-IntegrityTask.ps1 -Uninstall
```

## Bezpieczeństwo (świadome ograniczenia)

- Klucz AES i baza leżą na udziale hosta — OK na projekt; na produkcji rozdziel ochronę klucza.
- Automatyczny restore **tylko** dla wpisów z `|restore` (demo) — binaria Windows są raportowane, nie nadpisywane.
- Rootkit w kernelu może oszukiwać skan działający wewnątrz systemu — vault poza hostem to niezależny punkt odniesienia, nie pełna ochrona kernelowa.
- Po Windows Update przebuduj baseline (`New-Baseline.ps1`).



Ponowny deploy + scenariusz demo na VM (wymaga env):

```powershell
$env:LAB_SSH_PASSWORD = '...'
$env:LAB_DISCORD_WEBHOOK = 'https://discord.com/api/webhooks/...'
python tools\vm_deploy.py
```

Materiały prezentacji (`docs/`) są lokalne i nie są w repozytorium.
