#!/usr/bin/env python3
"""Replace the preview's LGPL binaries with the source-built release closure."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("runtime_build", ROOT / "scripts/build-wine-runtime.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--runtime", type=Path, required=True)
    p.add_argument("--dependencies", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    source, deps, output = a.runtime.resolve(), a.dependencies.resolve(), a.output.resolve()
    if source == output or source.is_relative_to(output) or output.is_relative_to(source):
        raise RuntimeError("Use a separate release staging directory")
    recipe = json.loads((deps / "recipe.json").read_text())
    if recipe["recipeSHA256"] != build.sha(ROOT / "scripts/build-runtime-deps.py"):
        raise RuntimeError("Dependency build recipe changed; rebuild before staging")
    for name, expected in recipe["outputSHA256"].items():
        if build.sha(deps / "prefix/lib" / name) != expected:
            raise RuntimeError("Built dependency changed after compilation: " + name)
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(source, output, symlinks=True)
    (output / "runtime.json").unlink(missing_ok=True)
    shutil.copytree(ROOT / "tools/wine-runtime/licenses", output / "Licenses", dirs_exist_ok=True)
    shutil.copy2(ROOT / "tools/wine-runtime/SOURCE-README.md", output / "Licenses/SOURCE-README.md")
    lib = output / "wine/lib"
    permissive = ("libMacportsLegacySupport", "libMoltenVK", "libbrotli", "libbz2", "libfreetype", "libpng", "libz.", "libzstd")
    for f in lib.glob("*.dylib"):
        if not f.name.startswith(permissive):
            f.unlink()
    for f in (deps / "prefix/lib").glob("*.dylib"):
        target = lib / f.name
        if target.exists() or target.is_symlink():
            target.unlink()
        if f.is_symlink():
            target.symlink_to(f.readlink())
        else:
            shutil.copy2(f, target)
    required = {"libgnutls.30.dylib", "libgmp.10.dylib", "libnettle.8.10.dylib", "libhogweed.6.10.dylib"}
    actual = {f.name for f in lib.glob("*.dylib") if not f.is_symlink() and not f.name.startswith(permissive)}
    if actual != required:
        raise RuntimeError(f"Unexpected non-permissive closure: {actual}")
    build.make_portable(output / "wine")
    build.audit(output / "wine")
    info = json.loads((output / "source.json").read_text())
    info["libraries"] = sorted(f.name for f in lib.glob("*.dylib"))
    info["selfBuiltDependencies"] = json.loads(json.dumps(recipe).replace(str(deps), "${DEPS_WORK}"))
    info["selfBuiltDependencies"]["preSignLibrarySHA256"] = {name: build.sha(lib / name) for name in sorted(required)}
    info["selfBuiltDependencies"]["stagingRecipeSHA256"] = build.sha(Path(__file__).resolve())
    info["permissiveBinaryDependencies"] = {"archive": info["sources"]["dependencies"],
        "regularLibraries": sorted(f.name for f in lib.glob("*.dylib") if not f.is_symlink() and f.name.startswith(permissive))}
    info["sources"].pop("dependencies")
    (output / "source.json").write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
    print("Staged release runtime with four source-built LGPL dependency libraries")


if __name__ == "__main__":
    main()
