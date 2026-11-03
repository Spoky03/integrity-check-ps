#!/usr/bin/env python3
"""Diagnose silent PS scripts on Win10 lab VM. Env: LAB_SSH_*."""
import base64
import os

import paramiko

HOST = os.environ.get("LAB_SSH_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAB_SSH_PORT", "2244"))
USER = os.environ.get("LAB_SSH_USER", "lab")
PASSWORD = os.environ.get("LAB_SSH_PASSWORD", "")


def connect():
    if not PASSWORD:
        raise SystemExit("Ustaw LAB_SSH_PASSWORD w środowisku.")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username=USER, password=PASSWORD, timeout=30, allow_agent=False, look_for_keys=False)
    return c


def run(c, cmd, timeout=120):
    _, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", errors="replace")
    err = stderr.read().decode("utf-8", errors="replace")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def ps(c, script, timeout=180):
    enc = base64.b64encode(script.encode("utf-16le")).decode("ascii")
    return run(c, f"powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand {enc}", timeout)


def main():
    c = connect()
    print("=== default shell / whoami ===")
    for cmd in [
        "echo SHELL_TEST",
        "whoami",
        r'powershell -NoProfile -Command "$PSVersionTable.PSVersion.ToString(); Get-ExecutionPolicy -List | Format-Table | Out-String"',
        r'cmd /c "cd /d C:\IntegrityCheck\src && .\New-Baseline.ps1"',
        r"powershell -NoProfile -ExecutionPolicy Bypass -File C:\IntegrityCheck\src\New-Baseline.ps1",
    ]:
        code, out, err = run(c, cmd, timeout=180)
        print(f"\n--- CMD: {cmd}\nexit={code}\nOUT:\n{out}\nERR:\n{err}")
    c.close()


if __name__ == "__main__":
    main()
