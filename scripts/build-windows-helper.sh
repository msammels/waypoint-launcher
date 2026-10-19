#!/bin/zsh
# Compile the small pipe/registry bridge without a Windows SDK or C runtime.
set -euo pipefail
root="${0:A:h}/.."
out="${1:-$root/build/windows-helper}"
mkdir -p "$out"
mode=()
if [[ "${2:-}" == "--titles" ]]; then
    mode=(-DWAYPOINT_TITLE_BRIDGE)
elif [[ -n "${2:-}" ]]; then
    print -u2 'usage: scripts/build-windows-helper.sh [output] [--titles]'
    exit 1
fi
clang -target x86_64-pc-windows-msvc -ffreestanding -fno-stack-protector -fno-builtin -Wall -Wextra -Werror -O2 "${mode[@]}" -c "$root/tools/windows-launch-options/launch-options.c" -o "$out/launch-options.obj"
for lib in kernel32 crypt32 advapi32; do
    lld-link /lib "/def:$root/tools/windows-launch-options/$lib.def" /machine:x64 "/out:$out/$lib.lib"
done
lld-link /Brepro /entry:mainCRTStartup /subsystem:windows /nodefaultlib /machine:x64 "$out/launch-options.obj" "$out/kernel32.lib" "$out/crypt32.lib" "$out/advapi32.lib" "/out:$out/waypoint-launch-options.exe"
