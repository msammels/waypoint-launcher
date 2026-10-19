#!/usr/bin/env python3
"""Exercise the actual PE bridge in a temporary owned prefix, with fake tickets.

No game files, user accounts or existing Wine prefixes are opened or changed.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument("--wine", type=Path, required=True)
p.add_argument("--helper", type=Path, required=True)
p.add_argument("--bridge", type=Path, required=True)
a = p.parse_args()
wine = a.wine.resolve()
helper = a.helper.resolve()
bridge = a.bridge.resolve()
current = helper
wine_root = wine.parent.parent
server = wine_root / "bin/wineserver"
ticket = "US-0123456789abcdef0123456789abcdef-1"

with tempfile.TemporaryDirectory(prefix="waypoint-bridge-protocol-") as tmp:
    prefix = Path(tmp) / "prefix"
    env = {k: v for k, v in os.environ.items() if not k.startswith(("WINE", "CX_", "DYLD_", "DXMT", "MTL_", "D3DM_"))}
    env.update(WINEPREFIX=str(prefix), WINEARCH="win64", WINEDEBUG="-all", WINEMSYNC="1",
               WINE_SIMULATE_WRITECOPY="1", WINEDLLOVERRIDES="winemenubuilder.exe=d;mscoree,mshtml=d",
               DYLD_LIBRARY_PATH=f"{wine_root}/lib:{wine_root}/lib/wine/x86_64-unix")
    def check(frame, status=87, output="ok\n"):
        # Persistent Wine services can inherit a pipe and keep its EOF open
        # after the helper has exited. Wait for the actual child, then read
        # its bounded acknowledgement from a temporary, synthetic-only file.
        with tempfile.TemporaryFile() as stdout:
            r = subprocess.run([str(wine), str(current)], input=frame.encode(), env=env,
                               stdout=stdout, stderr=subprocess.DEVNULL, timeout=45)
            stdout.seek(0)
            observed = stdout.read(1024)
        assert (r.returncode, observed) == (status, output.encode()), (r.returncode, observed)
    def control(title, action):
        return f"WAYPOINT-WINDOWS-2\n{title}\n{action}\n"
    keepalive = None
    try:
        subprocess.run([str(wine), "wineboot", "-u"], env=env, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=120, check=True)
        keepalive = subprocess.Popen([str(server), "-p"], env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # No valid test launch may resolve to an installed game.
        drive = prefix / "dosdevices/h:"
        if drive.is_symlink():
            drive.unlink()
        assert not drive.exists()
        check("prepare\n")
        check(f"WAYPOINT-HERO-1\n{ticket}\nEU\nenUS\n")
        check("probe\n", output="protected-ticket-valid\n")
        check("clear\n")
        check("probe\n", 3, "missing-token\n")
        check(control("pro", "prepare"), 2, "invalid-input\n")
        current = bridge
        check("prepare\n", 2, "invalid-input\n")
        check(control("hero", "prepare"), 2, "invalid-input\n")
        for title in ["pro", "osi", "fenris"]:
            check(control(title, "prepare"))
            check(control(title, "write") + f"{ticket}\nEU\nenUS\n")
            check(control(title, "probe"), output="protected-ticket-valid\n")
        check(control("pro", "clear"))
        check(control("pro", "probe"), 3, "missing-token\n")
        check(control("osi", "probe"), output="protected-ticket-valid\n")
        for frame in [control("unknown", "launch"), control("pro", "arbitrary.exe"),
                      control("pro", "write") + f"{ticket}\nEU\nenUS\nextra\n",
                      control("pro", "write") + f"{ticket}\nZZ\nenUS\n",
                      control("pro", "clear") + "extra\n", "x" * 2048]:
            check(frame, 2, "invalid-input\n")
        # Failed CreateProcess must remove the ticket it just wrote.
        check(control("pro", "launch") + f"{ticket}\nEU\nenUS\n", 8, "launch-failed\n")
        check(control("pro", "probe"), 3, "missing-token\n")
        for title in ["osi", "fenris"]:
            check(control(title, "clear"))
        print("Legacy and per-title DPAPI protocols, isolation, rejection and failed-launch cleanup passed")
    finally:
        # This environment points only to the newly created temporary prefix.
        subprocess.run([str(server), "-k"], env=env, capture_output=True, timeout=20)
        subprocess.run([str(server), "-w"], env=env, capture_output=True, timeout=20)
        if keepalive is not None:
            keepalive.wait(timeout=20)
