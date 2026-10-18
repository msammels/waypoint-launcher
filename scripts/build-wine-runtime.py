#!/usr/bin/env python3
"""Build Waypoint's optional, free x64 HotS runtime. Developer tool only.

Requires Xcode, Python 3.12+, bison 3, mingw-w64, FreeType/GnuTLS headers.
No installed CrossOver, license, proprietary GUI or D3DMetal is used.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

REPO = Path(__file__).resolve().parents[1]
INPUTS = {
    "wine": ("https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz",
             "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872"),
    "dependencies": ("https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz",
                     "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"),
    "dxmt": ("https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
             "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"),
}


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for data in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def run(args, **kwargs):
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def download(kind, cache):
    url, expected = INPUTS[kind]
    file = cache / url.rsplit("/", 1)[1]
    if not file.exists() or sha(file) != expected:
        cache.mkdir(parents=True, exist_ok=True)
        temporary = file.with_suffix(file.suffix + ".part")
        try:
            with urllib.request.urlopen(url, timeout=90) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            if sha(temporary) != expected:
                raise RuntimeError(f"Checksum mismatch: {kind}")
            temporary.replace(file)
        finally:
            temporary.unlink(missing_ok=True)
    return file


def extract(archive, destination, prefix=None):
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as tar:
        members = None if prefix is None else [m for m in tar if m.name == prefix or m.name.startswith(prefix + "/")]
        tar.extractall(destination, members=members, filter="data")


def extract_pinned(archive, destination, expected, prefix=None):
    stamp = destination / ".waypoint-archive-sha256"
    if stamp.exists() and stamp.read_text().strip() == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".extract-", dir=destination.parent) as temporary:
        unpacked = Path(temporary) / "payload"
        extract(archive, unpacked, prefix)
        source = unpacked / prefix if prefix else unpacked
        if destination.exists(): shutil.rmtree(destination)
        shutil.move(source, destination)
        stamp.write_text(expected + "\n")


def macho(path):
    with path.open("rb") as handle:
        return handle.read(4) in [b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe"]


def linked(path):
    text = subprocess.check_output(["otool", "-L", str(path)], text=True)
    return [line.strip().split(" (compatibility version", 1)[0] for line in text.splitlines()[1:]]


def install_id(path):
    lines = subprocess.check_output(["otool", "-D", str(path)], text=True).splitlines()
    return lines[1].strip() if len(lines) == 2 else None


def stage_libraries(source, destination, config):
    # These are loaded by name, not through the loader's static dependency list.
    pending = ["libfreetype.6.dylib", "libgnutls.30.dylib", "libMoltenVK.dylib"]
    for name in re.findall(r'^#define SONAME_\w+ "([^"]+)"', config, re.MULTILINE):
        # Wine always defines an ODBC fallback even when configure found no
        # library. HotS does not use SQL; this optional API returns unavailable.
        if name == "libodbc.dylib":
            continue
        if "/" in name:
            raise RuntimeError(f"Nonportable dlopen name: {name}")
        pending.append(name)
    copied = set()
    while pending:
        name = pending.pop()
        if name in copied:
            continue
        file = source / name
        if not file.exists():
            raise RuntimeError(f"Missing free runtime library: {name}")
        copied.add(name)
        target = destination / name
        if file.is_symlink():
            link = file.readlink()
            if link.is_absolute() or len(link.parts) != 1:
                raise RuntimeError(f"Nonportable library link: {name}")
            target.symlink_to(link)
            pending.append(str(link))
        else:
            shutil.copy2(file, target)
            identity = install_id(file)
            for dependency in linked(file):
                if dependency == identity or dependency.startswith(("/usr/lib/", "/System/Library/")):
                    continue
                base = Path(dependency).name
                if (source / base).exists():
                    pending.append(base)
                else:
                    raise RuntimeError(f"Unresolved dependency of {name}: {base}")
    return sorted(copied)


def make_portable(root):
    # All changes happen on the build machine, before signing. Users need no
    # install_name_tool, command-line tools, Homebrew or external libraries.
    for file in sorted(root.rglob("*")):
        if not file.is_file() or file.is_symlink() or not macho(file):
            continue
        dependencies = linked(file)
        identity = install_id(file)
        for dependency in dependencies:
            if dependency == identity:
                continue
            if dependency.startswith(("/usr/lib/", "/System/Library/", "@loader_path/", "@rpath/")):
                continue
            base = Path(dependency).name
            if (root / "lib" / base).exists() or (file.parent / base).exists():
                run(["install_name_tool", "-change", dependency, "@rpath/" + base, file])
            else:
                raise RuntimeError(f"Runtime depends on an external file: {file.name}: {dependency}")
        kind = subprocess.check_output(["file", "-b", str(file)], text=True)
        if "dynamically linked shared library" in kind:
            run(["install_name_tool", "-id", "@rpath/" + file.name, file])
        load = subprocess.check_output(["otool", "-l", str(file)], text=True)
        for path in re.findall(r'cmd LC_RPATH\n.*?path (.*?) \(offset', load, re.DOTALL):
            run(["install_name_tool", "-delete_rpath", path, file])
        paths = {"@loader_path", "@loader_path/" + os.path.relpath(root / "lib", file.parent)}
        for path in sorted(paths):
            if path == "@loader_path/.": continue
            run(["install_name_tool", "-add_rpath", path, file])
        run(["strip", "-S", file])


def audit(root):
    for file in sorted(root.rglob("*")):
        if not file.is_file() or file.is_symlink() or not macho(file):
            continue
        load = subprocess.check_output(["otool", "-l", str(file)], text=True)
        rpaths = re.findall(r'cmd LC_RPATH\n.*?path (.*?) \(offset', load, re.DOTALL)
        paths = [Path(p.replace("@loader_path", str(file.parent))) for p in rpaths]
        if any(not p.startswith("@loader_path") or not resolved.resolve().is_relative_to(root.resolve())
               for p, resolved in zip(rpaths, paths)):
            raise RuntimeError(f"Nonlocal runtime search path: {file}: {rpaths}")
        identity = install_id(file)
        for dependency in linked(file):
            if dependency == identity or dependency.startswith(("/usr/lib/", "/System/Library/")):
                continue
            if dependency.startswith("@rpath/"):
                candidates = [p / dependency.removeprefix("@rpath/") for p in paths]
            elif dependency.startswith("@loader_path/"):
                candidates = [file.parent / dependency.removeprefix("@loader_path/")]
            else:
                raise RuntimeError(f"External dependency: {file}: {dependency}")
            if not any(p.exists() and p.resolve().is_relative_to(root.resolve()) for p in candidates):
                raise RuntimeError(f"Unresolved dependency: {file}: {dependency}")
        info = subprocess.check_output(["vtool", "-show-build", str(file)], text=True)
        for version in re.findall(r'\bminos (\d+(?:\.\d+)*)', info):
            if tuple(int(p) for p in (version + ".0.0").split(".")[:3]) > (15, 0, 0):
                raise RuntimeError(f"Deployment target above macOS 15: {file}: {version}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, default=REPO / "build/wine-runtime-26.3")
    parser.add_argument("--cache", type=Path, default=REPO / "build/runtime-downloads")
    parser.add_argument("--output", type=Path, default=REPO / "build/windows-runtime/Windows")
    parser.add_argument("--stage-only", action="store_true", help="Package an already built, patched tree")
    parser.add_argument("--jobs", type=int, default=min(14, os.cpu_count() or 4))
    args = parser.parse_args()
    work = args.work.resolve()
    if " " in str(work):
        raise RuntimeError("Wine's build directory must not contain spaces")
    archives = {key: download(key, args.cache) for key in INPUTS}
    source = work / "source"
    patch = REPO / "tools/wine-runtime/patches/0001-initialize-missing-window-classes.patch"
    if args.stage_only and not (source / ".waypoint-archive-sha256").exists():
        raise RuntimeError("Stage-only requires a stamped recipe build")
    extract_pinned(archives["wine"], source, INPUTS["wine"][1], "sources/wine")
    applied = subprocess.run(["patch", "--dry-run", "-R", "-p1", "-i", str(patch)], cwd=source,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not applied:
        if args.stage_only:
            raise RuntimeError("The built Wine source does not contain the qualified window-class patch")
        run(["patch", "-p1", "-i", patch], cwd=source)
    dependency_package = work / "dependency-package"
    extract_pinned(archives["dependencies"], dependency_package, INPUTS["dependencies"][1])
    upstream_lib = dependency_package / "Wine Stable.app/Contents/Resources/wine/lib"
    libraries = work / "deps/lib"
    build_env = dict(os.environ)
    recipe_file = work / "build-recipe.json"
    recipe_inputs = {str(f.relative_to(REPO)): sha(f) for f in [Path(__file__).resolve(), REPO / "scripts/build-windows-helper.sh", REPO / "tools/windows-launch-options/launch-options.c", patch]}
    if not args.stage_only:
        if libraries.exists(): shutil.rmtree(libraries)
        libraries.mkdir(parents=True)
        for file in upstream_lib.glob("*.dylib"):
            target = libraries / file.name
            if target.exists() or target.is_symlink():
                target.unlink()
            if file.is_symlink(): target.symlink_to(file.readlink())
            else: shutil.copy2(file, target)
        for name, target in [("libfreetype.dylib", "libfreetype.6.dylib"), ("libgnutls.dylib", "libgnutls.30.dylib")]:
            if not (libraries / name).exists(): (libraries / name).symlink_to(target)
        # sfnt2fon is a build tool. SIP strips DYLD_* through system make/sh,
        # so give its FreeType input a usable install name during compilation.
        run(["install_name_tool", "-id", libraries / "libfreetype.6.dylib", libraries / "libfreetype.6.dylib"])
        run(["codesign", "--force", "--sign", "-", libraries / "libfreetype.6.dylib"])
        env = build_env
        empty_pkgconfig = work / "empty-pkgconfig"
        empty_pkgconfig.mkdir(exist_ok=True)
        mapping = f"-ffile-prefix-map={work}=."
        headers = "-I/opt/homebrew/opt/freetype/include/freetype2 -I/opt/homebrew/opt/gnutls/include"
        clang = subprocess.check_output(["xcrun", "-f", "clang"], text=True).strip()
        clangxx = subprocess.check_output(["xcrun", "-f", "clang++"], text=True).strip()
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        env.update(PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            SDKROOT=sdk,
            CC=f"{clang} -arch x86_64", CXX=f"{clangxx} -arch x86_64", OBJC=f"{clang} -arch x86_64",
            CFLAGS=f"-O2 -Wno-deprecated-declarations -Wno-format -mmacosx-version-min=14.6 {mapping}",
            OBJCFLAGS=f"-O2 -Wno-deprecated-declarations -mmacosx-version-min=14.6 {mapping}",
            CXXFLAGS=f"-O2 -mmacosx-version-min=14.6 {mapping}", CROSSCFLAGS=f"-O2 -Wno-incompatible-pointer-types {mapping}",
            LDFLAGS=f"-arch x86_64 -L{libraries} -Wl,-headerpad_max_install_names -mmacosx-version-min=14.6",
            CPPFLAGS=headers, CPATH="", LIBRARY_PATH=str(libraries), PKG_CONFIG_LIBDIR=str(empty_pkgconfig), PKG_CONFIG_PATH="",
            FREETYPE_CFLAGS="-I/opt/homebrew/opt/freetype/include/freetype2", GNUTLS_CFLAGS="-I/opt/homebrew/opt/gnutls/include",
            MACOSX_DEPLOYMENT_TARGET="14.6", FREETYPE_LIBS=f"-L{libraries} -lfreetype",
            GNUTLS_LIBS=f"-L{libraries} -lgnutls", ac_cv_lib_soname_freetype="libfreetype.6.dylib",
            ac_cv_lib_soname_gnutls="libgnutls.30.dylib")
        env["x86_64_CC"] = shutil.which("x86_64-w64-mingw32-gcc") or "x86_64-w64-mingw32-gcc"
        configure = [source / "configure", "--prefix=", "--host=x86_64-apple-darwin", "--build=x86_64-apple-darwin",
            "--disable-tests", "--disable-winedbg", "--enable-win64", "--enable-archs=x86_64",
            "--with-coreaudio", "--with-freetype", "--with-gnutls", "--with-mingw", "--with-pthread", "--with-unwind", "--with-vulkan"]
        configure += ["--without-" + name for name in ["alsa", "capi", "dbus", "ffmpeg", "fontconfig", "gettext", "gettextpo", "gphoto", "gssapi", "hwloc", "pcsclite",
            "gstreamer", "inotify", "krb5", "netapi", "oss", "pulse", "sane", "udev", "usb", "v4l2", "x", "wayland", "sdl", "pcap", "opencl", "cups"]]
        if (work / "obj").exists(): shutil.rmtree(work / "obj")
        (work / "obj").mkdir()
        keys = ["PATH", "SDKROOT", "CC", "CXX", "OBJC", "CFLAGS", "OBJCFLAGS", "CXXFLAGS", "CROSSCFLAGS", "LDFLAGS", "CPPFLAGS", "CPATH", "LIBRARY_PATH", "MACOSX_DEPLOYMENT_TARGET", "FREETYPE_CFLAGS", "FREETYPE_LIBS", "GNUTLS_CFLAGS", "GNUTLS_LIBS", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_PATH", "x86_64_CC", "ac_cv_lib_soname_freetype", "ac_cv_lib_soname_gnutls"]
        recipe = {"environment": {k: env[k].replace(str(work), "${WORK}") for k in keys},
                  "recipeFiles": recipe_inputs, "sourceClassSHA256": sha(source / "dlls/win32u/class.c"),
                  "waypointCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                  "dirtyTree": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=REPO, text=True).strip()),
                  "configure": [str(p).replace(str(work), "${WORK}") for p in configure],
                  "tools": {name: subprocess.check_output(command, env=env, text=True).splitlines()[:3]
                            for name, command in {"clang": [clang, "--version"], "xcode": ["xcodebuild", "-version"], "sdk": ["xcrun", "--show-sdk-version"], "mingw": [env["x86_64_CC"], "--version"], "bison": ["bison", "--version"], "headers": ["brew", "list", "--versions", "freetype", "gnutls"]}.items()}}
        recipe_file.write_text(json.dumps(recipe, indent=2, sort_keys=True) + "\n")
        run(configure, cwd=work / "obj", env=env)
        run(["make", f"-j{args.jobs}"], cwd=work / "obj", env=env)
    elif recipe_file.exists():
        recipe = json.loads(recipe_file.read_text())
        if recipe.get("recipeFiles") != recipe_inputs or recipe.get("sourceClassSHA256") != sha(source / "dlls/win32u/class.c"):
            raise RuntimeError("Recipe changed after compilation; perform a full build")
        build_env.update({k: v.replace("${WORK}", str(work)) for k, v in recipe["environment"].items()})
    else:
        raise RuntimeError("Stage-only requires the recorded build recipe")
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".windows-runtime-", dir=output.parent) as temporary:
        stage = Path(temporary)
        wine = stage / "wine"
        run(["make", "install-lib", f"DESTDIR={wine}"], cwd=work / "obj", env=build_env)
        strip_pe = shutil.which("x86_64-w64-mingw32-strip")
        if not strip_pe:
            raise RuntimeError("mingw-w64 strip is required")
        for file in wine.rglob("*"):
            if file.is_file() and not file.is_symlink() and file.suffix in [".dll", ".exe"]:
                run([strip_pe, "--strip-debug", file])
        included_libraries = stage_libraries(libraries, wine / "lib", (work / "obj/include/config.h").read_text())
        dxmt = work / "dxmt-package"
        extract_pinned(archives["dxmt"], dxmt, INPUTS["dxmt"][1])
        for name in ["d3d11.dll", "dxgi.dll", "winemetal.dll"]:
            shutil.copy2(dxmt / "v0.80/x86_64-windows" / name, wine / "lib/wine/x86_64-windows" / name)
        shutil.copy2(dxmt / "v0.80/x86_64-unix/winemetal.so", wine / "lib/wine/x86_64-unix/winemetal.so")
        make_portable(wine)
        audit(wine)
        run([REPO / "scripts/build-windows-helper.sh", stage / "helper-build"])
        shutil.copy2(stage / "helper-build/waypoint-launch-options.exe", stage / "waypoint-launch-options.exe")
        shutil.rmtree(stage / "helper-build")
        licenses = stage / "Licenses"
        shutil.copytree(REPO / "tools/wine-runtime/licenses", licenses)
        for name in ["LICENSE", "COPYING.LIB", "AUTHORS"]: shutil.copy2(source / name, licenses / ("Wine-" + name))
        shutil.copy2(patch, licenses / patch.name)
        source_info = {"recipe": 1, "wineSourceSHA256": INPUTS["wine"][1], "dxmtSHA256": INPUTS["dxmt"][1],
            "winePatchSHA256": sha(patch), "sources": {k: {"url": v[0], "sha256": v[1]} for k, v in INPUTS.items()},
            "libraries": included_libraries}
        if recipe_file.exists(): source_info["build"] = json.loads(recipe_file.read_text())
        source_info["waypointCommit"] = recipe["waypointCommit"]
        source_info["recipeFiles"] = recipe["recipeFiles"]
        (stage / "source.json").write_text(json.dumps(source_info, indent=2, sort_keys=True) + "\n")
        (licenses / "SOURCES.txt").write_text("Wine: LGPL-2.1-or-later; source and applied patch are listed in source.json.\n"
            "DXMT v0.80: MIT; https://github.com/3Shain/dxmt/tree/v0.80\n"
            "Supplementary FOSS libraries: the pinned Gcenx Wine release in source.json.\n"
            "No CodeWeavers application, license data, D3DMetal or Blizzard game binaries are included.\n")
        if output.exists(): shutil.rmtree(output)
        shutil.copytree(stage, output, symlinks=True)
    print(f"Staged free HotS runtime: {output}")


if __name__ == "__main__":
    main()
