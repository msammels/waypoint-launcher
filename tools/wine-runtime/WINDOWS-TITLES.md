# Experimental Windows Battle.net titles

The default release still enables only the qualified Windows HotS profile.
`WINDOWS_EXPERIMENTAL=1 scripts/bundle.sh` adds Overwatch, Diablo IV and Diablo
II: Resurrected to a development build. A runtime path override does not enable
these profiles in an ordinary release. Keep each new title gated until its
installation, Waypoint login and real rendering have been checked.

| Product | Install uid | Web/registry codename | Graphics | Current minimum |
| --- | --- | --- | --- | --- |
| Heroes of the Storm (`hero`) | `heroes` | `Hero` | DXMT 0.80 | macOS 15, Apple silicon, Rosetta |
| Overwatch (`pro`) | `prometheus` | `Pro` | DX11 through DXMT | macOS 15, Apple silicon, Rosetta |
| Diablo IV (`fenris`) | `fenris` | `Fen` | D3DMetal 3.0 | macOS 26.5, Apple silicon, Rosetta |
| Diablo II: Resurrected (`osi`) | `osi` | `OSI` | D3DMetal 3.0 | macOS 26.5, Apple silicon, Rosetta |

The Diablo minimum is a conservative qualification target, not a claim that
the graphics component itself cannot run on earlier macOS. New profiles must
not inherit HotS's spoofed adapter IDs or 120 FPS cap. Overwatch disables D3D12
so the DX11 profile is explicit. Game compatibility is separate from creating
a D3D12 device; the latter alone does not qualify a title.

## Installation and ownership

Blizzard's current HTTPS product configurations supply Windows build paths,
language tags and CASC layout. The existing downloader and installer are used;
no Windows Battle.net client is required. `SPWin`/`TPWin` are Windows markers
in Overwatch's product configuration. The installer rejects a mixed platform
folder, and Windows-only profiles cannot be installed as native macOS games.
Public configuration snapshots are test fixtures, not replacement servers.

Each title has its own prefix under `Windows/<product>/prefix-v1`. The released
HotS path remains `Windows/Heroes/prefix-v1`; its component cache continues to
use `Runtimes/heroes-<manifest SHA>`. A global launch lease serializes Windows
games, including preparation and authentication. Owned process checks use the
Wine loader path, game directory and executable name. Recovery and cleanup
never target another app's bottle or a global wineserver.

Documents folders stay inside the prefix rather than linking to native game
settings. The game's own shipped C/C++ DLLs are copied into that prefix.
Direct SSO uses the normal native Waypoint account flow and a per-title
[stdin bridge](../windows-launch-options/README.md). No copied Battle.net
account databases or credentials from another Wine prefix are needed.

## Optional Apple graphics component

The experimental app packages only a pinned manifest and the original license
text. On first use it presents the license in a native AppKit dialog. Acceptance
is keyed to the SHA-256 of the displayed bytes, which must match the downloaded
component's license. No Apple binaries are embedded in Waypoint or the existing
LGPL Wine runtime archive.

The downloader fetches the unmodified public
[Sikarugir Template 1.0.15 archive](https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.15.tar.xz)
(87,477,092 bytes, SHA-256
`34273bcce885ce5a7fd6937af9ea344bb9961de7d55d6193f7413142e835c8c3`).
Only its `renderer/d3dmetal` subtree is extracted. Verification checks every
listed file, relative symlink, archive hash and size; extra code is rejected.
Apple's framework and `libd3dshared.dylib` must also pass strict `anchor apple`
signature verification. These checks authenticate the pinned contents and
Apple-signed native libraries; PE files are authenticated by the pinned hash.
The original license accompanies the extracted files. It is not replaced by
Waypoint's license. Upstream distribution changes require a reviewed update.

Wine searches its own Unix DLL directory before `WINEDLLPATH`. Consequently,
an environment override alone silently selects its bundled vkd3d. Waypoint
creates a complete private Wine engine copy, overlays the verified Apple
libraries in the expected relative layout and validates the complete tree.
This immutable copy is keyed to both component manifests. Shared HotS/DXMT
files remain intact. Damaged copies are repaired atomically. The original
Apple framework and its signature remain intact in the overlay.

## Qualification evidence

On 2026-10-19 the production preparation path downloaded and verified the
component, prepared an isolated Diablo prefix and created a D3D12 feature-level
12.0 device through the private Metal engine. Reusing the verified cache also
succeeded. This is an infrastructure smoke test, not evidence of Diablo login,
license ownership, gameplay, performance or anti-cheat compatibility.

Unit tests cover public product profiles, platform separation, HotS environment
preservation, cross-title launch leases, bridge cache repair, graphics integrity,
offline reuse, license binding and Metal engine repair. The real legacy/v2 PE
bridge test covers DPAPI round trips with synthetic tickets and failed-launch
cleanup. Run it separately with an installed compatible Wine engine.

Useful primary references for launch identifiers:

- [Blizzard Overwatch launch log showing `-uid prometheus`](https://us.forums.blizzard.com/en/overwatch/t/game-wont-start-after-todays-patch-0xc000007b/935900/28)
- [Battle.net GOG integration implementation](https://github.com/bartok765/galaxy_blizzard_plugin)

Keep account identifiers, tokens, private qualification logs and screenshots
out of the repository. A purchased Diablo IV license must be confirmed by the
game itself before reporting a successful licensed launch.
