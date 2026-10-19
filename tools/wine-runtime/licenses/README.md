# Third-party runtime components

Waypoint's Windows HotS component uses the following freely redistributable
libraries. `sources.json` records the origin and SHA-256 of the license texts.
The runtime's `source.json` pins every input archive and the applied Wine patch.

| Component | License | Upstream source |
|---|---|---|
| Wine, CodeWeavers CrossOver 26.3 source release | LGPL-2.1-or-later | https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz |
| DXMT 0.80 | MIT, with zlib-licensed DXVK utilities | https://github.com/3Shain/dxmt/tree/v0.80 |
| LLVM 15.0.7 (linked by DXMT airconv) | Apache-2.0 with LLVM exceptions | https://github.com/llvm/llvm-project/tree/llvmorg-15.0.7 |
| FreeType 2.13.3 | FreeType License | https://gitlab.freedesktop.org/freetype/freetype/-/tree/VER-2-13-3 |
| GnuTLS 3.8.7 | LGPL-2.1-or-later, with its bundled LGPL libtasn1/unistring/gnulib sources | https://www.gnutls.org/download.html |
| Nettle / Hogweed 3.10.1 | LGPL-3.0-or-later or GPL-2.0-or-later | https://www.lysator.liu.se/~nisse/nettle/ |
| GMP 6.3.0 | LGPL-3.0-or-later or GPL-2.0-or-later | https://gmplib.org/download/gmp/ |
| Brotli 1.1.0 | MIT | https://github.com/google/brotli/tree/v1.1.0 |
| bzip2 1.0.8 | bzip2 license | https://sourceware.org/bzip2/ |
| libpng 1.6.45 | PNG Reference Library License | https://github.com/pnggroup/libpng |
| zlib 1.3.1 | zlib | https://github.com/madler/zlib/tree/v1.3.1 |
| Zstandard 1.5.6 | BSD-3-Clause | https://github.com/facebook/zstd/tree/v1.5.6 |
| MacPorts Legacy Support 1.4.0 | MIT | https://github.com/macports/macports-legacy-support/tree/v1.4.0 |
| MoltenVK 1.4.1 | Apache-2.0 and its upstream third-party notices | https://github.com/KhronosGroup/MoltenVK/tree/v1.4.1 |

The release builds GnuTLS, Nettle/Hogweed and GMP from the pinned pristine
archives in `dependency-sources.json`; its complete source inputs and build
recipes accompany the component. GnuTLS uses its bundled libtasn1/unistring
sources and does not link the preview's separate IDN, gettext, iconv, p11-kit
or libffi libraries. The staging script rejects an unexpected non-permissive
dependency library.

Remaining permissive dylibs come from the pinned Gcenx Wine 11.0_1 archive.
That project obtains them from MacPorts: https://github.com/Gcenx/macOS_Wine_builds
and https://github.com/macports/macports-ports. Only FreeType, MoltenVK and their
required permissive closure remain. Neither Gcenx's application nor its Wine
executable, Mono, Gecko or GStreamer is redistributed here. Extra license texts
from the development preview may remain as a superset of these notices.

The FreeType project (David Turner, Robert Wilhelm and Werner Lemberg) and
the other upstream authors retain their copyrights. The original library
notices and license texts accompany the runtime. LGPL-covered libraries
remain replaceable through the documented explicit local runtime override;
see [source and replacement instructions](../SOURCE-README.md). Reverse
engineering for debugging a modified version of those libraries is permitted
by their licenses.

The public release pipeline requires its complete corresponding LGPL source
archive and uploads it before the downloadable Windows component or live
appcast. The signed app's About credits and the component's `Licenses/SOURCES.txt`
point to the exact archive. Source URLs in this table alone do not replace
that release obligation.
