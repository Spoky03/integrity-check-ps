#!/usr/bin/env python3
"""Smoke-check New-Baseline output on lab VM. Env: LAB_SSH_*."""
import base64
import os

import paramiko

HOST = os.environ.get("LAB_SSH_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAB_SSH_PORT", "2244"))
USER = os.environ.get("LAB_SSH_USER", "lab")
PASSWORD = os.environ.get("LAB_SSH_PASSWORD", "")

if not PASSWORD:
    raise SystemExit("Ustaw LAB_SSH_PASSWORD w środowisku.")

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
print("connecting", flush=True)
c.connect(
    HOST,
    port=PORT,
    username=USER,
    password=PASSWORD,
    timeout=20,
    allow_agent=False,
    look_for_keys=False,
)
print("connected", flush=True)

script = r"""
$ErrorActionPreference = 'Continue'
Write-Output '=== START ==='
Write-Output ("Shell: " + $Host.Name)
Write-Output ("PS: " + $PSVersionTable.PSVersion)
Get-ExecutionPolicy -List | Out-String | Write-Output
Write-Output ("Test-Path src: " + (Test-Path 'C:\IntegrityCheck\src\New-Baseline.ps1'))
Set-Location 'C:\IntegrityCheck\src'
Write-Output '--- running New-Baseline.ps1 ---'
try {
  & '.\New-Baseline.ps1' 2>&1 | ForEach-Object { $_.ToString() }
} catch {
  Write-Output ('EXCEPTION: ' + $_)
}
Write-Output '=== END ==='
"""
enc = base64.b64encode(script.encode("utf-16le")).decode("ascii")
_, stdout, stderr = c.exec_command(
    f"powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand {enc}",
    timeout=180,
)
print("OUT:\n" + stdout.read().decode("utf-8", "replace"), flush=True)
print("ERR:\n" + stderr.read().decode("utf-8", "replace"), flush=True)
c.close()
