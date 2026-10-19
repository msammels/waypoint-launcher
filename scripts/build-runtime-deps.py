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
    "gnutls-3.8.7.tar.xz": "fe302f2b6ad5a564bcb3678eb61616413ed5277aaf8e7bf7cdb9a95a18d9f477",
}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--inputs", type=Path, required=True)
    p.add_argument("--work", type=Path, required=True)
    p.add_argument("--jobs", type=int, default=10)
    a = p.parse_args()
    recipe_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    work = a.work.resolve()
    prefix = work / "prefix"
    source = work / "sources"
    source.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.update(CC="clang -arch x86_64", CXX="clang++ -arch x86_64",
               CFLAGS=f"-O2 -mmacosx-version-min=14.6 -ffile-prefix-map={work}=.",
               CXXFLAGS=f"-O2 -mmacosx-version-min=14.6 -ffile-prefix-map={work}=.",
               CPPFLAGS=f"-I{prefix}/include", LDFLAGS=f"-arch x86_64 -L{prefix}/lib -mmacosx-version-min=14.6",
               PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"), PKG_CONFIG_PATH="",
               CPATH="", LIBRARY_PATH="", MACOSX_DEPLOYMENT_TARGET="14.6")
    common = [f"--prefix={prefix}", "--host=x86_64-apple-darwin", "--build=x86_64-apple-darwin",
              "--enable-shared", "--disable-static"]
    options = {
        "gmp-6.3.0": [],
        "nettle-3.10.1": ["--disable-documentation", "--disable-openssl"],
        "gnutls-3.8.7": ["--disable-doc", "--disable-tools", "--disable-tests", "--disable-cxx",
            "--sysconfdir=/etc", "--datadir=/usr/share",
            "--disable-nls", "--with-included-libtasn1", "--with-included-unistring", "--without-idn",
            "--without-p11-kit", "--without-tpm", "--without-tpm2", "--without-brotli", "--without-zstd",
            "--without-zlib", "--without-libiconv-prefix", "--without-libintl-prefix",
            "--with-default-trust-store-file=/etc/ssl/cert.pem",
            # 3.8.7 leaves these empty with --without-*; its Automake tests
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
    recipe = {"inputs": INPUTS, "commands": commands,
              "environment": {k: env[k] for k in ["CC", "CXX", "CFLAGS", "CPPFLAGS", "LDFLAGS", "PKG_CONFIG_LIBDIR"]},
              "recipeSHA256": recipe_hash}
    if recipe_hash != hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        raise RuntimeError("Build recipe changed during compilation; rerun the build")
    (work / "recipe.json").write_text(json.dumps(recipe, indent=2) + "\n")


if __name__ == "__main__":
    main()
