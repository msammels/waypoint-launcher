# D3D12 device smoke test

`zsh tools/windows-graphics-probe/build.sh` builds a small x64 PE with the
same clang/lld-link toolchain as the login bridge. No Windows SDK or CRT is
required. The probe calls `D3D12CreateDevice` with feature level 12.0 and releases
the device. It creates no window and performs no game rendering.

Run it only inside a prepared, owned test prefix with the title's production
Wine engine and environment. Success is exit **87** plus `device-created\n`.
Failure prints only the HRESULT and exits 1. Device creation through Wine's
bundled vkd3d is not evidence that the Apple graphics profile is working:
verify the selected engine and libraries too.

For the Diablo profile, use the complete `Runtimes/d3dmetal-<identity>/wine`
overlay produced by `WindowsGameSession.prepare`, rather than the shared
`heroes-<hash>/wine` engine. The first qualified smoke test on 2026-10-19 used
this production preparation path in an isolated support root and succeeded.
It does not establish game login, ownership, gameplay or FPS.
