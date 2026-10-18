#!/usr/bin/env python3
"""Sign bundled Windows components, then seal their cache manifest."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(file):
    digest = hashlib.sha256()
    with file.open("rb") as handle:
        for data in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("--identity", default="-")
    args = parser.parse_args()
    root = args.runtime.resolve()
    source = json.loads((root / "source.json").read_text())
    for file in sorted(root.rglob("*")):
        if not file.is_file() or file.is_symlink():
            continue
        with file.open("rb") as handle:
            magic = handle.read(4)
        if magic not in [b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe"]:
            continue
        kind = subprocess.check_output(["file", "-b", str(file)], text=True)
        command = ["codesign", "--force", "--sign", args.identity,
                   "--identifier", "dev.waypoint.launcher.windows." + re.sub(r"[^a-zA-Z0-9.-]", "-", str(file.relative_to(root)))]
        if args.identity != "-":
            command += ["--options", "runtime", "--timestamp"]
        if "executable" in kind:
            command += ["--entitlements", str(ROOT / "tools/wine-runtime/wine.entitlements")]
        subprocess.run(command + [str(file)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(file)], check=True)
    # Hash after signing: code signatures form part of the immutable cache ID.
    source["files"] = {
        str(file.relative_to(root)): sha(file)
        for file in sorted(root.rglob("*"))
        if file.is_file() and not file.is_symlink() and file.name != "runtime.json"
    }
    source["symlinks"] = {str(f.relative_to(root)): str(f.readlink()) for f in sorted(root.rglob("*")) if f.is_symlink()}
    source["fileModes"] = {str(f.relative_to(root)): stat.S_IMODE(f.stat().st_mode)
                           for f in sorted(root.rglob("*")) if f.is_file() and not f.is_symlink() and f.name != "runtime.json"}
    (root / "runtime.json").write_text(json.dumps(source, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
