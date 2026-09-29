#!/usr/bin/env python3
"""Test X.509 against its sibling checkout, restoring the tagged manifest."""
import fcntl
import json
import signal
import subprocess
import sys
from pathlib import Path


def interrupted(signum, frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupted)

root = Path(__file__).resolve().parents[1]
local = root.parent / "swift-authentication-x509"
manifest = root / "Package.swift"
if not (local / "Package.swift").is_file():
    sys.exit(f"Missing sibling package: {local}")
(root / ".build").mkdir(exist_ok=True)
with (root / ".build" / "local-x509-test.lock").open("w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    original = manifest.read_bytes()
    dependency = (
        b'.package(url: "https://github.com/swift-microservices/'
        b'swift-authentication-x509.git", from: "0.3.0")'
    )
    if original.count(dependency) != 1:
        sys.exit(
            "Expected exactly one tagged X.509 dependency; manifest left unchanged."
        )
    replacement = (".package(path: " + json.dumps(str(local)) + ")").encode()
    patched = original.replace(dependency, replacement)
    try:
        manifest.write_bytes(patched)
        result = subprocess.run(
            ["swift", "test", "--package-path", str(root), *sys.argv[1:]], check=False
        )
    finally:
        if manifest.read_bytes() == patched:
            manifest.write_bytes(original)
        else:
            sys.stderr.write(
                "Manifest changed during testing; preserving edits. "
                "Restore the tagged X.509 dependency manually.\n"
            )
    sys.exit(result.returncode)
