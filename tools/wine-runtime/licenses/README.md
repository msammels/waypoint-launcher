# Third-party runtime components

Waypoint's Windows HotS component uses the following freely redistributable
libraries. `sources.json` records the origin and SHA-256 of the license texts.
The runtime's `source.json` pins every input archive and the applied Wine patch.

| Component | License | Upstream source |
|---|---|---|
| Wine, CodeWeavers published 26.3 sources | LGPL-2.1-or-later | https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz |
| DXMT 0.80 | MIT, with zlib-licensed DXVK utilities | https://github.com/3Shain/dxmt/tree/v0.80 |
| LLVM 15.0.7 (linked by DXMT airconv) | Apache-2.0 with LLVM exceptions | https://github.com/llvm/llvm-project/tree/llvmorg-15.0.7 |
| FreeType 2.13.3 | FreeType License | https://gitlab.freedesktop.org/freetype/freetype/-/tree/VER-2-13-3 |
| GnuTLS 3.8.7 | LGPL-2.1-or-later; Nettle/GMP dependencies use LGPL-3.0-or-later | https://www.gnutls.org/download.html |
| Nettle / Hogweed | LGPL-3.0-or-later or GPL-2.0-or-later | https://www.lysator.liu.se/~nisse/nettle/ |
| GMP 6.3.0 | LGPL-3.0-or-later or GPL-2.0-or-later | https://gmplib.org/download/gmp/ |
| libidn2 2.3.7 | LGPL-3.0-or-later for the shared library | https://www.gnu.org/software/libidn/ |
| libtasn1 4.20.0 | LGPL-2.1-or-later for the shared library | https://www.gnu.org/software/libtasn1/ |
| libunistring 1.3 | LGPL-3.0-or-later or GPL-2.0-or-later | https://www.gnu.org/software/libunistring/ |
| libiconv | LGPL-2.1-or-later for the shared library | https://www.gnu.org/software/libiconv/ |
| libintl (GNU gettext) | LGPL-2.1-or-later for the runtime library | https://www.gnu.org/software/gettext/ |
| p11-kit | BSD-3-Clause | https://github.com/p11-glue/p11-kit |
| libffi | MIT | https://github.com/libffi/libffi |
| Brotli 1.1.0 | MIT | https://github.com/google/brotli/tree/v1.1.0 |
| bzip2 1.0.8 | bzip2 license | https://sourceware.org/bzip2/ |
| libpng | PNG Reference Library License | https://github.com/pnggroup/libpng |
| zlib 1.3.1 | zlib | https://github.com/madler/zlib/tree/v1.3.1 |
| Zstandard 1.5.6 | BSD-3-Clause | https://github.com/facebook/zstd/tree/v1.5.6 |
| MacPorts Legacy Support 1.4.0 | MIT | https://github.com/macports/macports-legacy-support/tree/v1.4.0 |
| MoltenVK 1.4.1 | Apache-2.0 and its upstream third-party notices | https://github.com/KhronosGroup/MoltenVK/tree/v1.4.1 |

Supplementary dylibs come from the pinned Gcenx Wine 11.0_1 archive. That
project obtains them from MacPorts: https://github.com/Gcenx/macOS_Wine_builds
and https://github.com/macports/macports-ports. Only the dependency closure of
FreeType, GnuTLS and MoltenVK is included. Neither Gcenx's application nor its
Wine executable, Mono, Gecko or GStreamer is redistributed here.

The FreeType project (David Turner, Robert Wilhelm and Werner Lemberg) and
the other upstream authors retain their copyrights. The original library
notices and license texts accompany the runtime. LGPL-covered libraries
remain dynamically replaceable; reverse engineering for debugging a modified
version of those libraries is permitted by their licenses.

Before publishing a binary release, provide its complete corresponding LGPL
sources, including the MacPorts dependency revisions and patches, alongside
the downloadable binary. These source links document provenance; they do not
replace that release obligation. Local development previews are not a public
binary release.
