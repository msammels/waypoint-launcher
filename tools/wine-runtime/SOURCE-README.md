# Waypoint Windows component: corresponding source

This archive accompanies the on-demand Windows component. `runtime-build.json`
records the Wine build and the exact dependency recipe. `inputs/manifest.json`
lists upstream archive URLs and hashes. `SHA256SUMS` covers this source package.
The component's `source.json` points back to this package and its SHA-256.
The native launcher source and all build/signing/staging scripts are in
`waypoint-source.tar.gz`. No Blizzard game files or account data are included.

Wine is built from CodeWeavers' CrossOver 26.3 LGPL source release, with the
included Waypoint startup patch. The runtime uses public DXMT 0.80. GnuTLS
3.8.7, Nettle 3.10.1 and GMP 6.3.0 are built from the included pristine archives.
GnuTLS's bundled libtasn1, libunistring and gnulib sources are within its archive.
No MacPorts-built LGPL library is redistributed in this component. FreeType,
MoltenVK and their remaining binary dependencies use permissive licenses; their
notices accompany the component. The original Wine build used GnuTLS 3.8.11
and FreeType 2.14.3 headers; those inputs are supplied separately too.

## Rebuild

Extract `waypoint-source.tar.gz` into a checkout. With Xcode, Python 3.12+,
Homebrew bison 3, mingw-w64, FreeType and GnuTLS development headers installed:

```sh
python3 scripts/build-wine-runtime.py --cache /absolute/path/to/inputs
python3 scripts/build-runtime-deps.py --inputs /absolute/path/to/inputs --work /tmp/waypoint-deps
python3 scripts/stage-release-runtime.py --runtime build/windows-runtime/Windows \
  --dependencies /tmp/waypoint-deps --output build/my-windows/Windows
python3 scripts/sign-wine-runtime.py build/my-windows/Windows --identity -
```

The first script downloads the pinned public DXMT and the permissive dependency
binary package if not cached. It uses only their required dependency closure;
the third script removes their LGPL binaries and substitutes the source-built
libraries. The recorded Wine configure arguments/toolchain versions are in
`runtime-build.json`. Signing identities/timestamps are not reproducible; an
Apple Developer ID is unnecessary for a personal local build.

## Use a modified compatible LGPL library

Copy the complete runtime directory to your own folder. Replace the desired
library with your compatible build, keeping its expected install name/ABI and
local `@rpath` dependencies. Generate a fresh manifest and ad-hoc signatures:

```sh
python3 scripts/sign-wine-runtime.py /absolute/path/to/my/Windows --identity -
defaults write dev.waypoint.launcher windowsRuntimeOverride -string /absolute/path/to/my/Windows
```

Quit Windows HotS and restart Waypoint, then press Play. The explicit local
override is copied into its own verified cache version; it does not change the
official downloaded package. Wine's entitlements permit replacement libraries.
Reverse engineering to debug modifications to LGPL libraries is permitted.
To restore the official component, quit HotS and run:

```sh
defaults delete dev.waypoint.launcher windowsRuntimeOverride
```

Restart Waypoint and press Play again. Keep the same original Wine/DXMT source
pins in `source.json`; update the build metadata for your own modifications.
See the included LGPL-2.1, LGPL-3.0 and GPL-3.0 texts for the full terms.
