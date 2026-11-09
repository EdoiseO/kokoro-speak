"""Generates one short clip through the network-denied worker and checks it.

Usage: <runtime>/.venv/bin/python -I scripts/selftest.py <runtime dir>
"""

import base64
import io
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import wave

SANDBOX = "(version 1)(allow default)(deny network*)"


def main():
    runtime = Path(sys.argv[1])
    environment = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
    worker = subprocess.Popen(
        ["/usr/bin/sandbox-exec", "-p", SANDBOX, str(runtime / ".venv/bin/python"), "-u", str(runtime / "worker.py")],
        cwd=runtime, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True,
    )

    def read():
        if not select.select([worker.stdout], [], [], 180)[0]:
            sys.exit("Self-test failed: the worker didn't respond.")
        return json.loads(worker.stdout.readline() or "null") or {}

    try:
        if read().get("event") != "ready":
            sys.exit("Self-test failed: the worker couldn't load the model.")
        command = {"rpcId": 1, "action": "start", "requestId": "selftest",
                   "text": "Kokoro Speak is ready.", "voice": "af_aoede", "speed": 1.0}
        worker.stdin.write(json.dumps(command) + "\n")
        worker.stdin.flush()
        result = read().get("result") or {}
        audio = base64.b64decode(result.get("audioBase64", ""))
        with wave.open(io.BytesIO(audio)) as clip:
            seconds = clip.getnframes() / clip.getframerate()
        if seconds <= 0:
            sys.exit("Self-test failed: no audio was generated.")
        print(f"    generated {seconds:.1f}s of audio")
    except (wave.Error, EOFError, ValueError):
        sys.exit("Self-test failed: the worker returned invalid audio.")
    finally:
        worker.terminate()
        worker.wait(timeout=5)


if __name__ == "__main__":
    main()
