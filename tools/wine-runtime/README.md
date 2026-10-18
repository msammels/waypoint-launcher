# Free Windows HotS runtime

This optional component is built from CodeWeavers' published Wine 26.3
LGPL source archive and the public MIT DXMT 0.80 release. It contains no
CrossOver application binaries, license data or D3DMetal. The name of the
source archive and Wine's internal `crossover` user profile do not introduce
a CrossOver license requirement.

Requirements for players: Apple silicon, macOS 15+, Rosetta. Waypoint itself
stays arm64. Wine, the small Windows login bridge and all required dylibs are
bundled; players need no compiler, Homebrew, Windows Battle.net or paid tool.

## Build

On a developer Mac with Xcode, Python 3.12+, Homebrew bison 3, mingw-w64,
FreeType and GnuTLS headers:

```sh
python3 scripts/build-wine-runtime.py
scripts/bundle.sh
```

Input downloads are SHA-256 pinned. Builds use an x64 Wine host and Windows
toolchain, a macOS 14.6 deployment target and public dependency libraries.
`--stage-only` repackages an already built, patched tree. `--cache`, `--work`
and `--output` allow existing downloads and build directories to be reused.
Build paths must not contain spaces; installed app, game and runtime paths can.

The bundle script includes `build/windows-runtime/Windows` when present.
`WINDOWS_RUNTIME=none scripts/bundle.sh` creates the small native-only app.
`WINDOWS_RUNTIME=/path/to/Windows` selects another staged component. Nested
Mach-O files are signed before generating `runtime.json`, then the app is
sealed. The Wine executables alone receive the execution/DYLD entitlements.

Wine's native libraries are stripped and their dependency paths relocated.
PE debug sections are removed before overlaying the unmodified pinned DXMT
files. Every deployed regular file is hashed after code signing. Waypoint
verifies and copies the component to a versioned cache so a running game can
outlive an app update. Inactive old copies are removed on a later launch.

Review [licenses](licenses/README.md) before distributing a binary release.

## Window-class patch

HotS' protected startup can leave Wine's desktop window initialized while
skipping the subsequent builtin-class registration. The first progress dialog
then fails with error 1411 before any game window appears. The patch retries
missing `GetClassInfoEx` lookups after registering builtins. It runs outside
`user_lock`, excludes Desktop/Message and guards same-thread callback
reentrancy around `pthread_once`. Existing classes keep their original path.

Claude Opus 5.5 (xhigh) reviewed the locking and callback contract. This is a
HotS-specific engine qualification, not a general Wine distribution. An
uncaught unwind through builtin initialization remains a limitation of this
once-based design; the tested HotS starts completed successfully.

## Native launch

The AppKit library keeps one HotS row with a Windows/macOS edition menu.
Windows is recommended when this component is available. Each edition has
independent installation records, CASC storage and game settings. Blizzard's
Windows files are downloaded through the existing installer.

Before authentication, Waypoint prepares a private Wine prefix, isolates its
Documents folders and maps H: to the Windows game folder. It copies the
game's own shipped runtime DLLs into that prefix. SSO uses Waypoint's existing
game/account login. The launch ticket is sent over an anonymous stdin pipe,
encrypted through Wine DPAPI and passed through Blizzard's registry channel.
It never appears in argv, environment, diagnostics or temporary files.

The bridge writes the ticket and starts the switcher in one Wine session,
then acknowledges both operations. Event-driven process observation follows
Switcher/Core transitions and clears the ticket after the game exits. A prefix
lease serializes preparation, login, launch and cleanup. Recovery targets
only Waypoint's own prefix.

Rendering uses DXMT 0.80, MSync, native display pixels, per-monitor DPI and
Metal pacing at the display's refresh rate. Existing game quality settings
are preserved. The launcher does not promise 120 FPS on every Mac or reuse
the measurements from a different CrossOver/DXMT build.
