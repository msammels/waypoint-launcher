#!/usr/bin/env python3
"""Check immutable component assets before publishing an app that refers to them."""
import argparse
import hashlib
import json
from pathlib import Path


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("directory", type=Path)
    p.add_argument("--app", type=Path)
    a = p.parse_args()
    root = a.directory.resolve()
    pub = json.loads((root / "publication.json").read_text())
    descriptor_path = root / "distribution/distribution.json"
    descriptor = json.loads(descriptor_path.read_text())
    if sha(descriptor_path) != pub["descriptorSHA256"]:
        raise RuntimeError("Component descriptor changed after packaging")
    if descriptor["manifestSHA256"] != pub["manifestSHA256"]:
        raise RuntimeError("Component manifest mismatch")
    if len(pub["assets"]) != 2 or {Path(a["name"]).suffix for a in pub["assets"]} != {".zip", ".tar"}:
        raise RuntimeError("Expected runtime and corresponding-source assets")
    for asset in pub["assets"]:
        if Path(asset["name"]).name != asset["name"] or asset["key"] != "windows/" + asset["name"]:
            raise RuntimeError("Invalid component publication path")
        f = root / asset["name"]
        if f.stat().st_size != asset["bytes"] or sha(f) != asset["sha256"]:
            raise RuntimeError("Component asset changed: " + asset["name"])
        if (root / (f.name + ".sha256")).read_text() != f"{asset['sha256']}  {f.name}\n":
            raise RuntimeError("Component checksum sidecar differs: " + f.name)
        url = "https://storage.yandexcloud.net/macos-releases/waypoint/" + asset["key"]
        if f.suffix == ".zip":
            if (descriptor["url"], descriptor["sha256"], descriptor["bytes"]) != (url, asset["sha256"], asset["bytes"]):
                raise RuntimeError("Runtime download differs from the signed descriptor")
        elif f.suffix == ".tar":
            if (descriptor["sourceURL"], descriptor["sourceSHA256"]) != (url, asset["sha256"]):
                raise RuntimeError("Corresponding-source download differs from the signed descriptor")
        else:
            raise RuntimeError("Unexpected component asset")
    if a.app:
        if sha(a.app / "Contents/Resources/WindowsRuntime/distribution.json") != pub["descriptorSHA256"]:
            raise RuntimeError("Built app refers to another Windows component")
        if (a.app / "Contents/SharedSupport/Windows").exists():
            raise RuntimeError("The release must download Windows components on demand")
    print("Windows runtime, corresponding sources and sealed descriptor match")


if __name__ == "__main__":
    main()
