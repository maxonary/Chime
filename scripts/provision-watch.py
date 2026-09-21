#!/usr/bin/env python3
"""Provision an installed personal Watch without putting credentials in the app bundle.
Use --fresh only on a first installation with no existing preferences file.
GATEWAY_URL is required; WATCH_TOKEN may override the single gateway/.env token.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from urllib.parse import urlparse

if len(sys.argv) < 2:
    sys.exit("Usage: provision-watch.py DEVICE_ID [--fresh]")
root = Path(__file__).resolve().parent.parent
url = os.environ.get("GATEWAY_URL", "")
if urlparse(url).scheme != "https" or not urlparse(url).hostname:
    sys.exit("Set GATEWAY_URL to your HTTPS gateway URL.")
token = os.environ.get("WATCH_TOKEN", "")
if not token:
    env = root / "gateway/.env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line.startswith("GATEWAY_TOKENS="):
                pairs = line.split("=", 1)[1].strip().strip('\"\'').split(",")
                if len(pairs) != 1:
                    sys.exit("Multiple gateway users: set WATCH_TOKEN for the intended user.")
                token = pairs[0].split(":", 1)[0]
if not token:
    sys.exit("Set WATCH_TOKEN or configure the single-user GATEWAY_TOKENS in gateway/.env.")
device = sys.argv[1]
bundle = "maxonary.chime.watchkitapp"
remote = f"Library/Preferences/{bundle}.plist"
base = ["xcrun", "devicectl", "device", "copy"]
options = ["--device", device, "--domain-type", "appDataContainer", "--domain-identifier", bundle, "--timeout", "30"]
(root / ".context").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="watch-provision-", dir=root / ".context") as directory:
    path = Path(directory) / "preferences.plist"
    result = subprocess.run(base + ["from", "--source", remote, "--destination", str(path)] + options, capture_output=True)
    if result.returncode:
        if "--fresh" not in sys.argv:
            sys.exit("Cannot read existing preferences. Check the Watch connection; use --fresh only for a first installation.")
        preferences = {}
    else:
        os.chmod(path, 0o600)
        preferences = plistlib.loads(path.read_bytes())
    settings = json.loads(preferences.get("appSettings", b"{}"))
    settings.update(gatewayURL=url, userToken=token)
    settings.setdefault("autoResearch", True)
    settings.setdefault("liveVoice", "marin")
    preferences["appSettings"] = json.dumps(settings).encode()
    path.write_bytes(plistlib.dumps(preferences, fmt=plistlib.FMT_BINARY))
    os.chmod(path, 0o600)
    result = subprocess.run(base + ["to", "--source", str(path), "--destination", remote] + options, capture_output=True)
    if result.returncode:
        sys.exit("Could not provision the Watch. Check its connection and retry.")
print("Watch configured; voice preferences and conversation data preserved.")
