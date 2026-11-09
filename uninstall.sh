#!/bin/zsh
# Removes Kokoro Speak, its runtime and model files, and its ⌥ Esc shortcut.
set -euo pipefail
osascript -e 'tell application id "com.kokorospeak.KokoroSpeak" to quit' >/dev/null 2>&1 || true
rm -rf "$HOME/Applications/Kokoro Speak.app" "$HOME/Library/Application Support/Kokoro Speak"
defaults delete com.kokorospeak.KokoroSpeak >/dev/null 2>&1 || true
/usr/bin/python3 -I - <<'PY'
import os, plistlib, subprocess, tempfile
path = os.path.expanduser("~/Library/Preferences/pbs.plist")
if os.path.exists(path):
    prefs = plistlib.load(open(path, "rb"))
    services = prefs.get("NSServicesStatus", {})
    for name in [n for n in services if n.startswith("com.kokorospeak.KokoroSpeak - ")]:
        del services[name]
    with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as file:
        plistlib.dump(prefs, file, fmt=plistlib.FMT_BINARY)
    subprocess.run(["defaults", "import", "pbs", file.name], check=True)
    os.unlink(file.name)
PY
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
echo "Kokoro Speak was removed."
