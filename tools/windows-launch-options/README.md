# Windows game hand-off

`scripts/build-windows-helper.sh` builds an x64 PE helper with Apple clang and
LLVM lld-link (tested with clang 21 and LLD 17). It needs no Windows SDK or CRT.
The released Wine component includes the legacy HotS helper; users need no
compiler. `scripts/build-windows-helper.sh build/windows-bridge --titles`
builds a separate title-aware helper for experimental native app bundles.

The helper accepts only bounded ASCII frames on stdin. `WAYPOINT-HERO-1`
writes a ticket, play region and optional locale to HotS' CurrentUser DPAPI
launch-options channel. `WAYPOINT-HERO-LAUNCH-1` also starts the fixed HotS
switcher on drive H in the same wineserver session. The runner must map H to
the chosen Windows installation and hold its prefix lease through startup.

Success requires both exit 87 and the exact `ok\n` acknowledgement. Wine can
exit 0 when its server disappears, so exit 0 is not an acknowledgement.
`probe` reports only whether a protected ticket has a valid shape; it never
prints the ticket. `clear` removes WEB_TOKEN without deleting other settings.

The pipe, arguments and diagnostics must never contain a real ticket except
for the ticket's stdin frame. Wine DPAPI is a compatibility mechanism, not a
replacement for Keychain. Keep the prefix private, clear after a failed
hand-off or game exit, and do not import another prefix's account state.

## Other Battle.net titles

The title bridge accepts only this protocol, and rejects the legacy HotS
frames and the `hero` title. The legacy helper rejects this protocol:

```text
WAYPOINT-WINDOWS-2
pro
launch
<ticket>
EU
enUS
```

The fixed allowlist is `pro` (Overwatch), `osi` (Diablo II: Resurrected) and
`fenris` (Diablo IV). Executables, working directories, arguments and registry
keys are compiled in; input cannot select an arbitrary executable. Overwatch's
product code is `pro`, but its install and launch uid is `prometheus`.
`prepare`, `probe` and `clear` accept no payload; `write` and `launch` require
exactly the three payload lines shown above. No extra lines are accepted.

The **v2 clear frame and per-title registry keys are a stable cleanup ABI**:
`WAYPOINT-WINDOWS-2\n<id>\nclear\n` must remain supported by future title
helpers. A game can outlive an app update; the replacement app must be able to
clear its ticket without importing the old app's executable. Helpers are
cached by SHA-256 under `Bridges`, independently of the Wine component.

Run the real PE protocol tests against a compatible Wine engine:

```sh
python3 tools/windows-launch-options/test-protocol.py \
  --wine /path/to/wine/bin/wine \
  --helper /path/to/legacy/waypoint-launch-options.exe \
  --bridge /path/to/title/waypoint-launch-options.exe
```

This creates and removes its own temporary prefix and uses synthetic tickets.
It checks both roles, per-title isolation, malformed frames and ticket cleanup
after a failed launch. It never opens existing prefixes or starts a game.
