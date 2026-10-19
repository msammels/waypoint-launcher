#!/bin/zsh
set -euo pipefail
root="${0:A:h}/../.."
out="${1:-$root/build/windows-graphics-probe}"
mkdir -p "$out"
clang -target x86_64-pc-windows-msvc -ffreestanding -fno-stack-protector -fno-builtin -Wall -Wextra -Werror -O2 \
    -c "$root/tools/windows-graphics-probe/d3d12.c" -o "$out/probe.obj"
print 'LIBRARY d3d12.dll\nEXPORTS\nD3D12CreateDevice' > "$out/d3d12.def"
lld-link /lib "/def:$out/d3d12.def" /machine:x64 "/out:$out/d3d12.lib"
lld-link /lib "/def:$root/tools/windows-launch-options/kernel32.def" /machine:x64 "/out:$out/kernel32.lib"
lld-link /Brepro /entry:mainCRTStartup /subsystem:windows /nodefaultlib /machine:x64 \
    "$out/probe.obj" "$out/kernel32.lib" "$out/d3d12.lib" "/out:$out/d3d12-probe.exe"
