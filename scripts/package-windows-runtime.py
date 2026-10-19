#!/usr/bin/env python3
"""Package an immutable, notarized on-demand Windows component and its sources."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
IDENTITY = "Developer ID Application: Misha Kharytonchyk (H8QG3CBM96)"
BASE = "https://storage.yandexcloud.net/macos-releases/waypoint/windows/"


def sha(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for data in iter(lambda: f.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--runtime", type=Path, required=True)
    p.add_argument("--inputs", type=Path, required=True)
    p.add_argument("--output", type=Path, default=ROOT / "build/windows-runtime-release")
    p.add_argument("--version", required=True)
    p.add_argument("--identity", default=IDENTITY)
    p.add_argument("--notary-profile", default="keys-cli-notary")
    a = p.parse_args()
    import re
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", a.version):
        raise RuntimeError("Expected a numeric component version")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT).strip():
        raise RuntimeError("Commit the release recipes before packaging")
    out = a.output.resolve()
    if out.exists():
        raise RuntimeError("Use a new output directory; published component bytes are immutable")
    out.mkdir(parents=True)
    info = json.loads((a.runtime / "source.json").read_text())
    if "selfBuiltDependencies" not in info:
        raise RuntimeError("Stage the source-built release dependencies first")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    inputs = a.inputs.resolve()
    downloads = json.loads((inputs / ("downloads.json" if (inputs / "downloads.json").exists() else "manifest.json")).read_text())
    archives = {"crossover-sources-26.3.0.tar.gz": info["wineSourceSHA256"],
                **info["selfBuiltDependencies"]["inputs"]}
    # The Wine build used these headers. Include their corresponding source
    # too, even though the shipped GnuTLS library is a separate build.
    archives["gnutls-3.8.11.tar.xz"] = "91bd23c4a86ebc6152e81303d20cf6ceaeb97bc8f84266d0faec6e29f17baa20"
    for name, expected in archives.items():
        if sha(inputs / name) != expected:
            raise RuntimeError("Source archive mismatch: " + name)
    source_name = f"Waypoint-Windows-{a.version}-sources.tar"
    with tempfile.TemporaryDirectory(dir=out) as td:
        tree = Path(td) / f"Waypoint-Windows-{a.version}-sources"
        (tree / "inputs").mkdir(parents=True)
        for name in archives:
            shutil.copy2(inputs / name, tree / "inputs" / name)
        (tree / "inputs/manifest.json").write_text(json.dumps({n: downloads[n] for n in archives}, indent=2) + "\n")
        run(["git", "archive", "--format=tar.gz", "-o", tree / "waypoint-source.tar.gz", commit], cwd=ROOT)
        shutil.copytree(ROOT / "tools/wine-runtime", tree / "notices-and-patches")
        (tree / "runtime-build.json").write_text(json.dumps(info, indent=2) + "\n")
        headers = Path("/opt/homebrew/opt/freetype/include")
        if headers.is_dir():
            shutil.copytree(headers, tree / "build-headers/freetype")
        shutil.copy2(ROOT / "tools/wine-runtime/SOURCE-README.md", tree / "README.md")
        sums = [f"{sha(f)}  {f.relative_to(tree)}" for f in sorted(tree.rglob("*")) if f.is_file()]
        (tree / "SHA256SUMS").write_text("\n".join(sums) + "\n")
        with tarfile.open(out / source_name, "w") as t:
            t.add(tree, arcname=tree.name)
    source_hash = sha(out / source_name)
    app = out / "Waypoint Windows Runtime.app"
    resources = app / "Contents/Resources/Windows"
    resources.parent.mkdir(parents=True)
    shutil.copytree(a.runtime, resources, symlinks=True)
    info["correspondingSource"] = {"url": BASE + source_name, "sha256": source_hash}
    info["componentVersion"] = a.version
    (resources / "source.json").write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
    (resources / "Licenses/SOURCES.txt").write_text(
        f"Corresponding source for this Windows component:\n{BASE}{source_name}\nSHA-256: {source_hash}\n\n"
        "Wine: LGPL-2.1-or-later. GnuTLS, Nettle and GMP: see included LGPL/GPL notices.\n"
        "GnuTLS includes its bundled libtasn1/unistring sources in the supplied source archive.\n"
        "DXMT: MIT. Remaining dependency binaries: permissive licenses listed here.\n"
        "See the source README for build steps and replacing a modified LGPL library.\n")
    run(["python3", ROOT / "scripts/sign-wine-runtime.py", resources, "--identity", a.identity])
    macos = app / "Contents/MacOS"
    macos.mkdir()
    c = out / "runtime-host.c"
    c.write_text("int main(void) { return 0; }\n")
    run(["xcrun", "clang", "-arch", "arm64", "-mmacosx-version-min=15.0", "-O2", c, "-o", macos / "Runtime"])
    c.unlink()
    plist = {"CFBundleExecutable": "Runtime", "CFBundleIdentifier": "dev.waypoint.launcher.windows-runtime",
             "CFBundleName": "Waypoint Windows Runtime", "CFBundlePackageType": "APPL",
             "CFBundleShortVersionString": a.version, "CFBundleVersion": a.version,
             "LSMinimumSystemVersion": "15.0", "LSBackgroundOnly": True}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
    run(["codesign", "--force", "--sign", a.identity, "--options", "runtime", "--timestamp", app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    archive = out / f"Waypoint-Windows-{a.version}.zip"
    run(["ditto", "-c", "-k", "--keepParent", app, archive])
    result = subprocess.run(["xcrun", "notarytool", "submit", str(archive), "-p", a.notary_profile,
                             "--wait", "--timeout", "1h", "--output-format", "json"], capture_output=True, text=True)
    (out / "notarization.json").write_text(result.stdout)
    if result.returncode or json.loads(result.stdout).get("status") != "Accepted":
        raise RuntimeError("Component notarization failed; inspect " + str(out / "notarization.json"))
    run(["xcrun", "stapler", "staple", app])
    run(["xcrun", "stapler", "validate", app])
    run(["spctl", "--assess", "--type", "execute", "--verbose", app])
    # Stapling changes the wrapper: the downloadable hash is computed last.
    archive.unlink()
    run(["ditto", "-c", "-k", "--keepParent", app, archive])
    manifest_hash = sha(resources / "runtime.json")
    descriptor = {"schema": 1, "url": BASE + archive.name, "bytes": archive.stat().st_size,
                  "sha256": sha(archive), "manifestSHA256": manifest_hash,
                  "sourceURL": BASE + source_name, "sourceSHA256": source_hash}
    distribution = out / "distribution"
    distribution.mkdir()
    (distribution / "distribution.json").write_text(json.dumps(descriptor, indent=2) + "\n")
    (distribution / "Credits.html").write_text(
        '<html><body style="font-family:-apple-system;font-size:11px">'
        '<p>Windows Heroes of the Storm uses Wine (LGPL), DXMT (MIT), and other open-source libraries.</p>'
        f'<p><a href="{html.escape(BASE + source_name)}">Corresponding source and license notices</a></p></body></html>')
    assets = [{"name": f.name, "key": "windows/" + f.name, "bytes": f.stat().st_size, "sha256": sha(f)}
              for f in [out / source_name, archive]]
    for f in [out / source_name, archive]:
        (out / (f.name + ".sha256")).write_text(f"{sha(f)}  {f.name}\n")
    publication = {"componentVersion": a.version, "sourceCommit": commit, "manifestSHA256": manifest_hash,
                   "descriptorSHA256": sha(distribution / "distribution.json"), "assets": assets}
    (out / "publication.json").write_text(json.dumps(publication, indent=2) + "\n")
    print("Ready: " + str(distribution / "distribution.json"), flush=True)


if __name__ == "__main__":
    main()
