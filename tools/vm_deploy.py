#!/usr/bin/env python3
"""Deploy IntegrityCheck to Win10 lab VM over SSH and run demo evidence capture."""

from __future__ import annotations

import os
import posixpath
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import paramiko

HOST = os.environ.get("LAB_SSH_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAB_SSH_PORT", "2244"))
USER = os.environ.get("LAB_SSH_USER", "lab")
PASSWORD = os.environ.get("LAB_SSH_PASSWORD", "")

ROOT = Path(__file__).resolve().parents[1]
REMOTE_ROOT = r"C:\IntegrityCheck"
REMOTE_VAULT = r"C:\IntegrityVault"
REMOTE_DEMO = r"C:\IntegrityDemo\demo-file.txt"
EVIDENCE = ROOT / "docs" / "DEMO_EVIDENCE.md"

# Ustaw LAB_DISCORD_WEBHOOK w środowisku — nigdy nie commituj prawdziwego URL
WEBHOOK = os.environ.get(
    "LAB_DISCORD_WEBHOOK",
    "https://discord.com/api/webhooks/CHANGE_ME/CHANGE_ME",
)

UPLOAD_DIRS = ["src", "samples"]
UPLOAD_FILES = [
    "config/paths.example.psd1",
    "config/file-scope.example.txt",
]


def connect() -> paramiko.SSHClient:
    if not PASSWORD:
        raise SystemExit(
            "Brak LAB_SSH_PASSWORD w środowisku. "
            "Przykład (PowerShell): $env:LAB_SSH_PASSWORD='...'; $env:LAB_DISCORD_WEBHOOK='...'"
        )
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        HOST,
        port=PORT,
        username=USER,
        password=PASSWORD,
        timeout=30,
        allow_agent=False,
        look_for_keys=False,
    )
    return client


def run(client: paramiko.SSHClient, command: str, timeout: int = 180) -> tuple[int, str, str]:
    stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def ps(client: paramiko.SSHClient, script: str, timeout: int = 180) -> tuple[int, str, str]:
    # Escape for powershell -EncodedCommand is safer for complex scripts
    import base64

    # PowerShell expects UTF-16LE for -EncodedCommand
    encoded = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    return run(client, f'powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand {encoded}', timeout)


def section(title: str, body: str) -> str:
    return f"\n## {title}\n\n```text\n{body.rstrip()}\n```\n"


def main() -> int:
    evidence: list[str] = [
        "# Dowody działania — lab Win10 (SSH)",
        "",
        f"- Data (UTC): `{datetime.now(timezone.utc).isoformat()}`",
        f"- Host SSH: `{USER}@{HOST}:{PORT}`",
        f"- Katalog projektu na VM: `{REMOTE_ROOT}`",
        f"- Vault na VM (lab): `{REMOTE_VAULT}` — w prezentacji podkreśl, że docelowo to shared folder hosta",
        "",
    ]

    print("Connecting…")
    client = connect()
    print("SSH OK")

    code, out, err = ps(
        client,
        r"""
$info = [pscustomobject]@{
  User = $env:USERNAME
  Computer = $env:COMPUTERNAME
  PS = $PSVersionTable.PSVersion.ToString()
  OS = (Get-CimInstance Win32_OperatingSystem).Caption
  Z = (Test-Path 'Z:\')
  Drives = (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name + ':' }).Trim() -join ', '
}
$info | Format-List | Out-String
""",
    )
    probe = (out + err).strip()
    print(probe)
    evidence.append(section("1. Połączenie SSH / środowisko VM", probe))

    # Prepare remote dirs + config via PowerShell
    cfg_script = rf"""
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path '{REMOTE_ROOT}\src','{REMOTE_ROOT}\config','{REMOTE_ROOT}\samples','{REMOTE_VAULT}','C:\IntegrityDemo' | Out-Null
Write-Output 'dirs-ready'
"""
    code, out, err = ps(client, cfg_script)
    print("dirs:", out.strip(), err.strip())

    # Upload with SFTP (avoid scp package dependency issues)
    sftp = client.open_sftp()

    def ensure_remote_dir(path: str) -> None:
        # path like C:\IntegrityCheck\src → normalize for SFTP which often wants /
        parts = path.replace("/", "\\").split("\\")
        # skip drive letter piece carefully
        cur = parts[0] + "\\"
        for p in parts[1:]:
            if not p:
                continue
            cur = cur.rstrip("\\") + "\\" + p
            try:
                sftp.stat(cur)
            except IOError:
                try:
                    sftp.mkdir(cur)
                except IOError:
                    pass

    def put_file(local: Path, remote: str) -> None:
        ensure_remote_dir(str(Path(remote).parent))
        print(f"PUT {local} -> {remote}")
        sftp.put(str(local), remote)

    for rel in UPLOAD_FILES:
        put_file(ROOT / rel, str(Path(REMOTE_ROOT) / rel.replace("/", "\\")))

    for d in UPLOAD_DIRS:
        local_dir = ROOT / d
        for f in local_dir.rglob("*"):
            if f.is_file():
                rel = f.relative_to(ROOT)
                remote = str(Path(REMOTE_ROOT) / str(rel))
                put_file(f, remote)

    sftp.close()

    # Write VM-specific config (webhook + vault + demo scope)
    write_cfg = rf"""
$ErrorActionPreference = 'Stop'
$root = '{REMOTE_ROOT}'
@(
  '@{{'
  "    VaultRoot          = '{REMOTE_VAULT}'"
  "    BaselineFileName   = 'baseline.aes'"
  "    KeyRelativePath    = 'secrets\aes.key'"
  "    CopiesRelativePath = 'trusted_copies'"
  "    LogsRelativePath   = 'logs'"
  "    EventLogSource     = 'IntegrityCheck'"
  "    EventLogName       = 'Application'"
  "    DiscordWebhookUrl  = '{WEBHOOK}'"
  "    FileScopePath      = 'config\file-scope.txt'"
  '    AutoRestore        = $true'
  '    ReportOnly         = $false'
  '}}'
) | Set-Content -Path (Join-Path $root 'config\paths.psd1') -Encoding UTF8

Set-Location (Join-Path $root 'src')
.\Initialize-LabTargets.ps1 | Out-String

$scope = @(
  '# Lab VM allowlista'
  'C:\Windows\System32\notepad.exe'
  'C:\Windows\System32\cmd.exe'
  'C:\IntegrityDemo\demo-file.txt|restore'
  'C:\Windows\Temp\IntegrityCheck-probe.txt|restore'
)
if (Test-Path -LiteralPath 'C:\Windows\System32\IntegrityCheck-probe.txt') {{
  $scope += 'C:\Windows\System32\IntegrityCheck-probe.txt|restore'
}}
$scope | Set-Content -Path (Join-Path $root 'config\file-scope.txt') -Encoding UTF8

Get-ChildItem -Recurse $root | Select-Object FullName, Length | Format-Table -AutoSize | Out-String
Get-Content (Join-Path $root 'config\paths.psd1') | Where-Object {{ $_ -match 'VaultRoot|DiscordWebhookUrl|FileScope' }}
Write-Output '---scope---'
Get-Content (Join-Path $root 'config\file-scope.txt')
Write-Output '---lab-targets---'
Get-Item 'C:\IntegrityDemo\demo-file.txt','C:\Windows\Temp\IntegrityCheck-probe.txt','C:\Windows\System32\IntegrityCheck-probe.txt' -ErrorAction SilentlyContinue |
  Select-Object FullName, Length | Format-Table -AutoSize | Out-String
"""
    code, out, err = ps(client, write_cfg)
    deploy_out = (out + ("\n" + err if err.strip() else "")).strip()
    print(deploy_out)
    # redact webhook token in evidence
    redacted = deploy_out
    if WEBHOOK in redacted:
        redacted = redacted.replace(WEBHOOK, "https://discord.com/api/webhooks/REDACTED/REDACTED")
    evidence.append(section("2. Deploy plików + konfiguracja na VM", redacted))

    # Etap A
    code, out, err = ps(
        client,
        rf"""
$ErrorActionPreference = 'Stop'
Set-Location '{REMOTE_ROOT}\src'
.\New-Baseline.ps1 -ForceNewKey | Out-String
Write-Output '---vault---'
Get-ChildItem -Recurse '{REMOTE_VAULT}' | Select-Object FullName, Length | Format-Table -AutoSize | Out-String
""",
        timeout=300,
    )
    a_out = (out + ("\n" + err if err.strip() else "")).strip()
    print(a_out)
    evidence.append(section("3. Etap A — New-Baseline.ps1", a_out))

    # Etap B clean
    code, out, err = ps(
        client,
        rf"""
$ErrorActionPreference = 'Stop'
Set-Location '{REMOTE_ROOT}\src'
$r = .\Invoke-Verify.ps1 -SkipResponse
'FindingCount=' + $r.FindingCount
'OkCount=' + $r.OkCount
$r.Results | Format-Table Path, Status, ExpectedSha256, ActualSha256 -AutoSize | Out-String
""",
        timeout=300,
    )
    b1 = (out + ("\n" + err if err.strip() else "")).strip()
    print(b1)
    evidence.append(section("4. Etap B — pierwsza weryfikacja (oczekiwane OK)", b1))

    # Tamper — demo + sondy w Windows\Temp / System32 (domyślne cele Simulate-Tamper)
    code, out, err = ps(
        client,
        rf"""
$ErrorActionPreference = 'Stop'
Set-Location '{REMOTE_ROOT}\src'
.\Simulate-Tamper.ps1 -Mode Append | Format-Table -AutoSize | Out-String
Write-Output '---demo---'
Get-Content 'C:\IntegrityDemo\demo-file.txt' -ErrorAction SilentlyContinue
Write-Output '---temp-probe---'
Get-Content 'C:\Windows\Temp\IntegrityCheck-probe.txt' -ErrorAction SilentlyContinue
Write-Output '---system32-probe---'
Get-Content 'C:\Windows\System32\IntegrityCheck-probe.txt' -ErrorAction SilentlyContinue
""",
    )
    t_out = (out + ("\n" + err if err.strip() else "")).strip()
    print(t_out)
    evidence.append(section("5. Symulacja podmiany — Simulate-Tamper.ps1", t_out))

    # Etap B+C
    code, out, err = ps(
        client,
        rf"""
$ErrorActionPreference = 'Stop'
Set-Location '{REMOTE_ROOT}\src'
$r = .\Invoke-Verify.ps1
'FindingCount=' + $r.FindingCount
'Discord=' + $r.Response.Discord
'Restored=' + (($r.Response.Restored | ConvertTo-Json -Compress))
$r.Results | Format-Table Path, Status, ExpectedSha256, ActualSha256 -AutoSize | Out-String
Get-Content '{REMOTE_VAULT}\logs\integrity.log' -Tail 15
""",
        timeout=300,
    )
    b2 = (out + ("\n" + err if err.strip() else "")).strip()
    print(b2)
    evidence.append(section("6. Etap B+C — detekcja, Discord, restore", b2))

    # Verify after restore
    code, out, err = ps(
        client,
        rf"""
$ErrorActionPreference = 'Stop'
Set-Location '{REMOTE_ROOT}\src'
$r = .\Invoke-Verify.ps1 -SkipResponse
'FindingCount=' + $r.FindingCount
$r.Results | Format-Table Path, Status -AutoSize | Out-String
Get-Content 'C:\IntegrityDemo\demo-file.txt'
""",
    )
    b3 = (out + ("\n" + err if err.strip() else "")).strip()
    print(b3)
    evidence.append(section("7. Ponowna weryfikacja po restore (oczekiwane OK)", b3))

    # Optional: try install scheduled task (may need admin)
    code, out, err = ps(
        client,
        rf"""
$ErrorActionPreference = 'Continue'
Set-Location '{REMOTE_ROOT}\src'
try {{
  .\Install-IntegrityTask.ps1 -IntervalMinutes 30 2>&1 | Out-String
  Get-ScheduledTask -TaskName 'IntegrityCheck-Verify' -ErrorAction SilentlyContinue | Format-List TaskName, State | Out-String
}} catch {{
  'TASK_INSTALL_FAILED: ' + $_.Exception.Message
}}
""",
    )
    task = (out + ("\n" + err if err.strip() else "")).strip()
    print(task)
    evidence.append(section("8. Task Scheduler (może wymagać Administratora)", task))

    evidence.extend(
        [
            "",
            "## Co wstawić do prezentacji (screeny)",
            "",
            "1. Ten log SSH + `hostname` / dyski (środowisko lab).",
            "2. Eksplorator `C:\\IntegrityVault` z `baseline.aes`, `secrets\\aes.key`, `trusted_copies`.",
            "3. Konsola Etap A (hashe notepad/cmd/demo).",
            "4. Verify OK (tabela Status=OK).",
            "5. Po `Simulate-Tamper` — Status=Changed dla demo-file.",
            "6. Kanał Discord — alert IntegrityCheck.",
            "7. Log `C:\\IntegrityVault\\logs\\integrity.log` + restore Success.",
            "8. Ponowny Verify OK + treść demo-file przywrócona.",
            "9. (Jeśli admin) Harmonogram `IntegrityCheck-Verify`.",
            "",
            "## Uwagi",
            "",
            "- Webhook w dowodach jest zredagowany; w live demo widać prawdziwy alert na Discordzie.",
            "- Hasło lab użyte tylko do SSH — nie umieszczaj go na slajdach.",
            "",
        ]
    )

    EVIDENCE.write_text("\n".join(evidence), encoding="utf-8")
    print("Wrote", EVIDENCE)
    client.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("FAIL:", type(exc).__name__, exc)
        raise
