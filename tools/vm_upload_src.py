#!/usr/bin/env python3
"""Upload src/ to lab VM. Credentials via env: LAB_SSH_HOST/PORT/USER/PASSWORD."""
import os
from pathlib import Path

import paramiko

ROOT = Path(__file__).resolve().parents[1]
REMOTE = r"C:\IntegrityCheck\src"
HOST = os.environ.get("LAB_SSH_HOST", "127.0.0.1")
PORT = int(os.environ.get("LAB_SSH_PORT", "2244"))
USER = os.environ.get("LAB_SSH_USER", "lab")
PASSWORD = os.environ.get("LAB_SSH_PASSWORD", "")

if not PASSWORD:
    raise SystemExit("Ustaw LAB_SSH_PASSWORD w środowisku przed uruchomieniem.")

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, port=PORT, username=USER, password=PASSWORD, timeout=20, allow_agent=False, look_for_keys=False)
sftp = c.open_sftp()
for f in (ROOT / "src").iterdir():
    if f.is_file():
        remote = str(Path(REMOTE) / f.name)
        print("PUT", f.name)
        sftp.put(str(f), remote)
sftp.close()
c.close()
print("done")
