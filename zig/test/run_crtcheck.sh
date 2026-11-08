#!/bin/sh
# run_crtcheck.sh - check the Zig runtime's printf, strtod and sscanf against the system glibc:
# tools/crt/test/mkfmt.c writes about 1.3 million reference cases from glibc, test/crtcheck.zig replays them
# through src/rt.zig and counts the differences. The vectors go to a temporary folder and are deleted.
set -e
cd "$(dirname "$0")/.."
if command -v zig >/dev/null 2>&1; then ZIG=zig; else ZIG="python3 -m ziglang"; fi
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache}" ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache}"
T=$(mktemp -d "${TMPDIR:-/tmp}/zigcrt.XXXXXX")
gcc -O2 -o "$T/mkfmt" ../tools/crt/test/mkfmt.c -lm
"$T/mkfmt" > "$T/fmt.txt"
$ZIG build-exe -O ReleaseFast -mcpu=x86_64 -fno-builtin -fno-compiler-rt -lc -lm --dep rt -Mroot=test/crtcheck.zig -Mrt=src/rt.zig \
    -femit-bin="$T/crtcheck" --name crtcheck
"$T/crtcheck" "$T/fmt.txt"
rm -rf "$T"
