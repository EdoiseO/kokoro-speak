#!/bin/zsh
# Installs Kokoro Speak: the Python runtime, the model files, and the menu bar app.
# Safe to re-run; finished steps are skipped. Usage: ./install.sh
set -euo pipefail

ROOT=${0:A:h}
RUNTIME="$HOME/Library/Application Support/Kokoro Speak"
LEGACY="$HOME/Library/Application Support/Kokoro Speak Selection/kokoro"
APP_DEST="$HOME/Applications/Kokoro Speak.app"
BUNDLE_ID="com.kokorospeak.KokoroSpeak"
SERVICE_KEY="$BUNDLE_ID - Speak with Kokoro Speak - speakSelection"

step() { print -P "%B==>%b $1"; }
die() { print -P "%F{red}Error:%f $1" >&2; exit 1; }

# 1. Requirements -------------------------------------------------------------
[[ $(uname -m) == arm64 ]] || die "Kokoro Speak needs an Apple silicon Mac (M1 or later)."
[[ ${$(sw_vers -productVersion)%%.*} -ge 13 ]] || die "Kokoro Speak needs macOS 13 or later."
command -v swift >/dev/null || die "Swift isn't installed. Run: xcode-select --install"
PYTHON=$(command -v python3.13 || true)
[[ -n $PYTHON ]] || die "Python 3.13 isn't installed. Run: brew install python@3.13"

mkdir -p "$RUNTIME/models/mlx"
chmod 700 "$RUNTIME"

# 2. Python environment (exact, hash-checked wheels) ---------------------------
LOCK="$ROOT/runtime/requirements.lock"
LOCK_SHA=$(shasum -a 256 "$LOCK" | cut -d' ' -f1)
if [[ $(cat "$RUNTIME/.venv/.lock-sha256" 2>/dev/null) != "$LOCK_SHA" ]]; then
  step "Creating the Python environment"
  rm -rf "$RUNTIME/.venv"
  "$PYTHON" -m venv "$RUNTIME/.venv"
  "$RUNTIME/.venv/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --no-deps --only-binary=:all: -r "$LOCK"
  print "$LOCK_SHA" > "$RUNTIME/.venv/.lock-sha256"
else
  step "Python environment is up to date"
fi

# 3. Model files (about 355 MB, checked against pinned SHA-256 hashes) -----------
step "Checking model files"
"$RUNTIME/.venv/bin/python" -I - "$ROOT/runtime/models.json" "$RUNTIME" "$LEGACY" <<'PY'
import hashlib, json, shutil, subprocess, sys
from pathlib import Path

manifest, runtime, legacy = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()

for asset in json.load(open(manifest))["assets"]:
    dest = runtime / asset["path"]
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_file() and sha256(dest) == asset["sha256"]:
        print(f"    {asset['path']}: ok")
        continue
    old = legacy / asset["path"]
    if old.is_file() and sha256(old) == asset["sha256"]:
        subprocess.run(["cp", "-c", str(old), str(dest)], check=True)  # APFS clone, no extra disk use
        print(f"    {asset['path']}: reused existing copy")
        continue
    print(f"    {asset['path']}: downloading {asset['size'] / 1e6:.0f} MB")
    partial = dest.with_suffix(dest.suffix + ".part")
    subprocess.run(["curl", "-fL", "--retry", "3", "--progress-bar", "-o", str(partial), asset["url"]], check=True)
    if sha256(partial) != asset["sha256"]:
        partial.unlink()
        sys.exit(f"Checksum mismatch for {asset['path']}; the download was discarded.")
    partial.replace(dest)
PY

cp "$ROOT/runtime/worker.py" "$ROOT/runtime/engine.json" "$RUNTIME/"

# 4. Self-test: generate a short clip with no network access ------------------
step "Testing speech generation"
"$RUNTIME/.venv/bin/python" -I "$ROOT/scripts/selftest.py" "$RUNTIME"

# 5. Build and install the app -------------------------------------------------
step "Setting up local code signing"
"$ROOT/scripts/make-signing-cert.sh"

step "Building the app"
"$ROOT/scripts/build-app.sh" >/dev/null
osascript -e 'tell application id "'"$BUNDLE_ID"'" to quit' >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R "$ROOT/build/Kokoro Speak.app" "$APP_DEST"

# 6. ⌥ Esc ----------------------------------------------------------------------
# The app registers ⌥ Esc itself as a global hotkey. Earlier versions bound it to the
# app's Services entry instead; remove that binding so one press doesn't trigger twice.
/usr/bin/python3 -I - "$SERVICE_KEY" <<'PY'
import os, plistlib, subprocess, sys, tempfile

path = os.path.expanduser("~/Library/Preferences/pbs.plist")
if os.path.exists(path):
    with open(path, "rb") as file:
        prefs = plistlib.load(file)
    entry = prefs.get("NSServicesStatus", {}).get(sys.argv[1], {})
    if entry.pop("key_equivalent", None) is not None:
        # Import as a binary plist: other entries may hold an ESC byte, which XML can't store.
        with tempfile.NamedTemporaryFile(suffix=".plist", delete=False) as file:
            plistlib.dump(prefs, file, fmt=plistlib.FMT_BINARY)
        subprocess.run(["defaults", "import", "pbs", file.name], check=True)
        os.unlink(file.name)
        subprocess.run(["/System/Library/CoreServices/pbs", "-update"], capture_output=True)
PY

open "$APP_DEST"
step "Done. Select text in any app and press ⌥ Esc. Press it again to stop."
print "    The first time, macOS asks you to allow Kokoro Speak in Privacy & Security > Accessibility"
print "    so it can read the text you've selected. Turn it on, then press ⌥ Esc again."
