# Architektura

## Cel

Niezależny punkt odniesienia (sumy SHA-256) do wykrywania podmienionych plików systemowych / demo — zgodnie z prezentacją wstępną projektu.

## Przepływ

```
Allowlista (file-scope)
        │
        ▼
┌───────────────────┐     AES-256      ┌─────────────────────┐
│  New-Baseline.ps1 │ ───────────────► │ Host vault          │
│  Get-FileHash     │                  │  baseline.aes       │
│  trusted_copies   │                  │  secrets/aes.key    │
└───────────────────┘                  │  trusted_copies/    │
                                       │  logs/              │
┌───────────────────┐   decrypt+hash   └──────────▲──────────┘
│ Invoke-Verify.ps1 │ ◄───────────────────────────┘
└─────────┬─────────┘
          │ rozbieżność
          ▼
┌───────────────────┐
│Invoke-Response.ps1│──► Event Log + plik logu
│                   │──► Discord webhook
│                   │──► restore (tylko |restore)
└───────────────────┘
```

## Moduł `IntegrityCheck.psm1`

Wspólna logika:

| Funkcja | Rola |
|---------|------|
| `Get-IntegrityFileRecord` | SHA-256 + metadane |
| `Protect-IntegrityBaseline` / `Unprotect-...` | AES-256-CBC, IV prefixowany do pliku |
| `Compare-IntegrityBaseline` | OK / Changed / Missing / New |
| `Send-IntegrityDiscordAlert` | webhook JSON |
| `Restore-IntegrityFile` | kopia z vaultu + re-hash |

## Dlaczego vault na hoście?

Prezentacja wymaga, by baza i kopie były **poza** skanowanym systemem. Shared folder (VirtualBox/VMware) montowany jako `Z:\IntegrityVault` jest najprostszym wariantem labowym. Atak ograniczony do guest OS nie powinien mieć pełnej, niewykrywalnej kontroli nad baseline na hoście (przy założeniu, że hypervisor / host nie jest skompromitowany).

## Ograniczenia

1. **Aktualizacje Windows** zmieniają legalnie hashe → przebudowa baseline, tryb `-ReportOnly`.
2. **Rootkit w kernelu** może fałszować odczyty plików widziane przez PowerShell w gościu — narzędzie nie zastępuje boot/kernel integrity (Secure Boot, HVCI itd.).
3. **Restore systemowych binariów** jest celowo wyłączony bez `|restore` — unikamy psucia OS i walki z WFP/UAC.
4. **Klucz obok bazy** na tym samym udziale jest kompromisem dydaktycznym; produkcja: HSM / osobny sekret / bitlocker hosta.
