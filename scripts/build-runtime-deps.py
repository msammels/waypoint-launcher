#!/usr/bin/env python3
"""Build the runtime's LGPL dependency closure from pinned, supplied sources.

No system installation or MacPorts binary provenance is required. The input
archives and this recipe accompany the downloadable Windows runtime.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile

INPUTS = {
    "gmp-6.3.0.tar.xz": "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898",
    "nettle-3.10.1.tar.gz": "b0fcdd7fc0cdea6e80dcf1dd85ba794af0d5b4a57e26397eee3bc193272d9132",
    "gnutls-3.8.13.tar.xz": "ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e",
}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--inputs", type=Path, required=True)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--jobs", type=int, default=10)
    a = p.parse_args()
    recipe_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    work = a.work.resolve()
    if work.exists() and any(work.iterdir()):
        raise RuntimeError("Use an empty work directory for a clean source build")
    work.mkdir(parents=True, exist_ok=True)
    prefix = work / "prefix"
    source = work / "sources"
    source.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    clang = subprocess.check_output(["xcrun", "-f", "clang"], text=True).strip()
    clangxx = subprocess.check_output(["xcrun", "-f", "clang++"], text=True).strip()
    builtin = subprocess.check_output([clang, "-print-resource-dir"], text=True).strip()
    includes = f"-nostdinc -isystem {builtin}/include -isystem {sdk}/usr/include -F{sdk}/System/Library/Frameworks -isysroot {sdk}"
    env.update(CC=f"{clang} -arch x86_64", CXX=f"{clangxx} -arch x86_64",
               CFLAGS=f"-O2 -mmacosx-version-min=14.6 -ffile-prefix-map={work}=. {includes}",
               CXXFLAGS=f"-O2 -mmacosx-version-min=14.6 -ffile-prefix-map={work}=.",
               CPPFLAGS=f"-I{prefix}/include", LDFLAGS=f"-arch x86_64 -L{prefix}/lib -L{sdk}/usr/lib -F{sdk}/System/Library/Frameworks -Wl,-Z -mmacosx-version-min=14.6",
               PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"), PKG_CONFIG_PATH="",
               CPATH="", LIBRARY_PATH="", MACOSX_DEPLOYMENT_TARGET="14.6", SDKROOT=sdk,
               PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    common = [f"--prefix={prefix}", "--host=x86_64-apple-darwin", "--build=x86_64-apple-darwin",
              "--enable-shared", "--disable-static"]
    options = {
        "gmp-6.3.0": [],
        "nettle-3.10.1": ["--disable-documentation", "--disable-openssl"],
        "gnutls-3.8.13": ["--disable-doc", "--disable-tools", "--disable-tests", "--disable-cxx", "--disable-libdane",
            "--sysconfdir=/etc", "--datadir=/usr/share",
            "--disable-nls", "--with-included-libtasn1", "--with-included-unistring", "--without-idn",
            "--without-p11-kit", "--without-tpm", "--without-tpm2", "--without-brotli", "--without-zstd",
            "--without-zlib", "--without-libiconv-prefix", "--without-libintl-prefix",
            "--with-default-trust-store-file=/etc/ssl/cert.pem",
            # Older releases leave these empty with --without-*; Automake tests
            # empty != no and otherwise still compiles unused dlopen wrappers.
            "with_libzstd=no", "with_libbrotlienc=no", "with_libbrotlidec=no"],
    }
    commands = []
    for name, expected in INPUTS.items():
        archive = (a.inputs / name).resolve()
        if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Source hash mismatch: {name}")
        stem = name.removesuffix(".tar.xz").removesuffix(".tar.gz")
        tree = source / stem
        if not tree.exists():
            with tarfile.open(archive) as t:
                t.extractall(source, filter="data")
        obj = work / ("obj-" + stem)
        obj.mkdir(exist_ok=True)
        configure = [str(tree / "configure"), *common, *options[stem]]
        commands.append(configure)
        subprocess.run(configure, cwd=obj, env=env, check=True)
        subprocess.run(["make", f"-j{a.jobs}"], cwd=obj, env=env, check=True)
        subprocess.run(["make", "install"], cwd=obj, env=env, check=True)
    outputs = {}
    for f in sorted((prefix / "lib").glob("*.dylib")):
        if f.is_symlink():
            continue
        identity = subprocess.check_output(["otool", "-D", f], text=True).splitlines()[1].strip()
        links = subprocess.check_output(["otool", "-L", f], text=True).splitlines()[1:]
        for line in links:
            name = line.strip().split(" (compatibility version")[0]
            if name == identity or name.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if not name.startswith(str(prefix / "lib") + "/") or not Path(name).exists():
                raise RuntimeError("External library dependency: " + name)
        outputs[f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
    if set(outputs) != {"libgmp.10.dylib", "libnettle.8.10.dylib", "libhogweed.6.10.dylib", "libgnutls.30.dylib"}:
        raise RuntimeError("Unexpected source-built dependency output set")
    recipe = {"inputs": INPUTS, "commands": commands, "outputSHA256": outputs,
              "environment": {k: env[k] for k in ["CC", "CXX", "CFLAGS", "CPPFLAGS", "LDFLAGS", "PKG_CONFIG_LIBDIR"]},
              "recipeSHA256": recipe_hash}
    if recipe_hash != hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        raise RuntimeError("Build recipe changed during compilation; rerun the build")
    (work / "recipe.json").write_text(json.dumps(recipe, indent=2) + "\n")


if __name__ == "__main__":
    main()
