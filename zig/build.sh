#!/bin/sh
# build.sh - build the Zig port of EPA SWMM 5.2.4:  bin/runswmm <input> <report> [output]
# Needs Zig 0.15.2 (pip install ziglang==0.15.2 provides `python3 -m ziglang`; a `zig` on PATH is used first).
#   -O ReleaseFast   no safety checks; the generated code wraps integers itself (+% -% *%)
#   -mcpu=x86_64     the baseline x86-64 EPA's gcc build targets: no FMA instruction can appear
#   -fno-builtin     LLVM keeps every libm call as written (no pow(x,2) -> x*x, pow(2,x) -> exp2(x),
#                    no constant folding with the compiler's own math library)
#   -fno-compiler-rt Zig's compiler-rt carries its own exp, log, log10, sin, cos, tan and floor, and the
#                    linker would bind the engine's calls to those copies instead of glibc's
#                    (lessons/19); without it every libm call is an import from libm.so.6
#   -lc -lm          glibc for low-level I/O and glibc's libm, the library EPA calls
# BUILD_MODE=ReleaseSafe BIN_SUFFIX=_safe ./build.sh builds a checked engine (bounds, overflow and cast traps);
# without compiler-rt it also needs -fno-stack-check (no stack probes), which the script adds.
set -e
cd "$(dirname "$0")"
if command -v zig >/dev/null 2>&1; then ZIG=zig; else ZIG="python3 -m ziglang"; fi
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache}" ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache}"
mkdir -p bin
MODE=${BUILD_MODE:-ReleaseFast}
EXTRA=""
[ "$MODE" = ReleaseFast ] || EXTRA="-fno-stack-check"
$ZIG build-exe src/main.zig -O "$MODE" -mcpu=x86_64 -fno-builtin -fno-compiler-rt $EXTRA -lc -lm \
    -femit-bin=bin/runswmm${BIN_SUFFIX:-} --name runswmm
