# Windows HotS hand-off

`scripts/build-windows-helper.sh` builds an x64 PE helper with Apple clang and
LLVM lld-link (tested with clang 21 and LLD 17). It needs no Windows SDK or CRT.
The release app includes the resulting helper; users need no compiler.

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
