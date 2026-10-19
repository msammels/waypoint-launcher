#!/usr/bin/env python3
"""Fetch and verify the committed LGPL source inputs for a release."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--output", type=Path, default=ROOT / "build/release-source-inputs")
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=True)
    inputs = json.loads((ROOT / "tools/wine-runtime/dependency-sources.json").read_text())
    for name, record in inputs.items():
        file = a.output / name
        if not file.exists():
            part = a.output / (name + ".part")
            subprocess.run(["curl", "-fL", "--retry", "2", "--connect-timeout", "15", "--max-time", "300",
                            "-o", str(part), record["url"]], check=True)
            part.rename(file)
        if hashlib.sha256(file.read_bytes()).hexdigest() != record["sha256"]:
            raise RuntimeError("Source hash mismatch: " + name)
        record["size"] = file.stat().st_size
    (a.output / "downloads.json").write_text(json.dumps(inputs, indent=2) + "\n")


if __name__ == "__main__":
    main()
