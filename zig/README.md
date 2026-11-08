# swmm5-zig

EPA SWMM 5.2.4 in Zig, written by a translator that reads EPA's C, and judged against EPA itself: the binary
`.out` file byte for byte, and the `.rpt` report line for line except the three lines that print the wall clock.

**Result: 480 of 480 models identical** (`gate/results/zig_5.json`, log `gate/zig_5_run.txt`). The 480 took
138 seconds of wall time run one at a time (the sum of the per-model times the gate records; EPA's reference
run, made earlier on a differently loaded machine, records 256 s; no interleaved benchmark was run, so no speed
ratio is claimed).

It is not a new engine. Every number it writes is EPA 5.2.4's, including the results of EPA's own defects
wherever EPA's behaviour is defined (`lessons/02-epa-defects-found.md`).

## The parity contract

The same as the earlier ports (see `go/` or the swmm5-go repository): EPA SWMM 5.2.4 built from the USEPA
v5.2.4 tag with gcc 13.3 `-O2` on x86-64 Linux with glibc 2.39 (`ref/Makefile`); each model run in its own
folder; pass = `.out` byte-identical (when EPA writes one) and `.rpt` identical after removing `Analysis begun
on`, `Analysis ended on` and `Total elapsed time`, the exit code the same (EPA's command line always exits 0).
When an input error stops EPA before it writes results, the engine must not write a results file either.
Corpus: the 480 gate models of `gate/models_all.tsv` from SWMMBobSWMM6/1729-SWMM5-Models-2030.

## Build and run

Requires Zig 0.15.2 (`pip install ziglang==0.15.2` provides `python3 -m ziglang`; a `zig` on the PATH is used
first) and glibc's libm.

```sh
zig/build.sh
zig/bin/runswmm model.inp model.rpt model.out
```

`build.sh` explains each flag. Three matter for the numbers: `-mcpu=x86_64` (the baseline instruction set EPA's
gcc build targets, so no fused multiply-add instruction can appear: `objdump -d` finds none), `-fno-builtin`
(LLVM keeps every libm call as written instead of folding `pow(1.1, 2.5)`, turning `pow(x, 2.0)` into `x*x` or
`pow(2.0, x)` into `exp2(x)`), and `-fno-compiler-rt` (Zig's own compiler-rt defines exp, log, log10, sin,
cos, tan and floor, and would capture the engine's calls; `lessons/19-zig-brings-its-own-libm.md`).
`BUILD_MODE=ReleaseSafe BIN_SUFFIX=_safe zig/build.sh` builds a checked engine (`zig/bin/runswmm_safe`).

## How it was made

`tools/c2x/front.py` parses EPA's 54 C files with libclang; `tools/c2x/emit_zig.py` (1,738 lines) writes the
whole engine as one Zig file, `zig/src/swmm5.zig` (39,134 lines, generated); the hand-written runtime
`zig/src/rt.zig` (1,672 lines) supplies the C library pieces SWMM uses, and `zig/src/main.zig` (50 lines) is
EPA's `run/main.c`. When the port disagreed with EPA, the fix went into the translator or the runtime, never
into the generated file.

Zig has C's memory model, so unlike the managed-language ports this one keeps C's data layout and pointers:

- `int`, `unsigned`, `long`, `char`, `double`, `float` become `i32`, `u32`, `i64`, `i8`, `f64`, `f32`;
  structs and the one union are `extern struct`/`extern union` (C's layout; a comptime block at the end of the
  generated file checks every record's size against the C compiler's); `T*` is `[*c]T`, Zig's C pointer, so
  indexing, pointer arithmetic, NULL and `void*` casts translate directly. `odesolve.c` and `mempool.c`, which
  the managed ports replace by hand, are translated like the rest; nothing in EPA is overridden.
- Zig converts nothing implicitly that could lose information, so every C conversion is written out
  (`@floatFromInt`, `@truncate`, `@bitCast`, ...); `(int)x` of a double goes through `R.d2i`, x86's
  `cvttsd2si` rule (NaN or out of range gives `INT_MIN`; `lessons/02`, defect 2).
- Integer `+ - *` are Zig's wrapping `+% -% *%` (C's wrap-around on x86-64; plain Zig operators trap in a
  checked build and are undefined in a fast one); `/` and `%` on signed integers are `@divTrunc`/`@rem`; a
  signed array index is sign-extended (`ix(i)`), so a C negative index works.
- C's assignments, `++`, `?:` and comma used as values become labelled blocks and `if` expressions, evaluated
  in C's order; switch becomes a Zig `switch` inside a labelled block (C's `break` leaves the block, and a
  section that falls through runs a copy of the next section's code); `do`/`while` with `continue` becomes
  `while (first or cond) : (first = false)`.
- Zig forbids shadowing and unused locals, so locals are hoisted to the top of each function with unique
  names, zeroed, and marked used (`_ = &x;`); statements after a `return` or `break` are dropped (Zig rejects
  unreachable code).
- Float literals: Zig reads a decimal literal to 128 bits and then rounds it to `f64`, which could round twice,
  so the translator writes the shortest decimal only where it checks (with exact fractions) that this cannot
  happen, and the exact hexadecimal form otherwise; a literal next to another constant is typed
  `@as(f64, ...)` so Zig's compile-time arithmetic rounds each step in `f64` as C does.

## The runtime and the math library

- **printf/snprintf** (`rt.zig`): the exact decimal expansion of the binary value from a small big-integer
  routine, rounded half to even, as glibc does; %g built from it as C99 specifies.
- **strtod/atof/sscanf**: glibc's syntax (decimal, hexadecimal, `inf`, `nan(...)` with its payload), the digits
  then converted by Zig's `std.fmt.parseFloat` (correctly rounded: Eisel-Lemire with an exact fallback);
  `%f` into a `float` is rounded once from the text, as `strtof`.
- Checked against glibc 2.39 by `zig/test/run_crtcheck.sh` (1,394,252 cases from `tools/crt/test/mkfmt.c`):
  **1 differs**, `%#g` of 999999.75, where glibc prints `1.e+06` and the port `1.00000e+06`, the same single
  case the Go port reports; SWMM never uses `%#g`. Output: `zig/test/crtcheck_result.txt`.
- **stdio** over libc's `open`, `pread`, `pwrite`, `write` and `close`: C's position, end-of-file flag and
  buffering (a port of the Go runtime's file layer); `fread`/`fwrite` move raw bytes, as C's do.
- **Memory** from Zig's `std.heap.smp_allocator`, every block zero-filled with a size header; `calloc(0)`
  still gives a block, as glibc's does.
- **Math**: `exp`, `log`, `log10`, `pow`, `sin`, `cos`, `tan`, `asin`, `acos` and `atan` are glibc's own, called
  through `extern "m"`; the binary imports exactly the versioned symbols EPA imports (`exp@GLIBC_2.29`,
  `pow@GLIBC_2.29`, `sin@GLIBC_2.2.5`, ...; compare `nm -D zig/bin/runswmm` with `nm -D ref/runswmm`).
  `fabs`, `sqrt`, `floor` and `ceil` are Zig's builtins, which are exact. So, like the Fortran and C# ports,
  this port follows EPA on whatever CPU both run on, including glibc's choice of FMA routines.

## How it was checked

| Run | Engine | Result |
|---|---|---|
| zig_1 | first build, compiler-rt linked | 441 of 480 (39 differ in the last digits: compiler-rt's exp/log/sin/cos, lessons/19) |
| zig_2 | `-fno-compiler-rt`, the 39 | 39 of 39 |
| zig_3 | the same build, all 480 | 480 of 480 |
| zig_safe_1 | ReleaseSafe (bounds, overflow and cast checks on) | 3 of 480: every other model trapped in `rt.zig`'s `calloc(0)`, which returned a pointer one past its block |
| zig_safe_2 | ReleaseSafe after that fix | 480 of 480, no trap |
| zig_4 | ReleaseFast after that fix | 480 of 480 |
| **zig_5** | **final build** (`zig/build.sh`): the generated file now also makes Zig compile every translated function, reached or not | **480 of 480** |

All runs: `python3 gate/gate.py NAME "$PWD/zig/runswmm_saves.sh" -j 1 --timeout 3600 --prune`, inside
`flock` on the shared corpus lock. `runswmm_saves.sh` backs up every file a deck SAVEs (listed by the swmm6-rust
repository's `gate/savefiles.py`, called read-only) and restores it after the run, so a deck that SAVEs RDII
never changes the file another deck USEs (`Hydrology/cho.txt` was 1,114,474 bytes, md5
5b0ca1fe78588202fa779dbfa417b089, before and after every run). The checked runs used
`SWMM_BIN=zig/bin/runswmm_safe`, built `-O ReleaseSafe -fno-stack-check` (a checked build without compiler-rt
needs no stack probes). The generated file was regenerated from the final translator and compared: identical.
The checked runs used the generated file before the `comptime` block was added (the block adds no code to a
path the command line runs).

## What this does not show

- That SWMM is right: identical to EPA means EPA's answers, good or bad.
- Other platforms: the port calls the system libm, so on another machine it should follow EPA built there;
  only x86-64 Linux with glibc 2.39 was run.
- Paths no gate model exercises: streets and inlets (one deck, which stops on input errors), climate files,
  USE HOTSTART, USE INFLOWS, USE RUNOFF. Zig compiles only what is reached from `main`, so the generated file
  ends with a `comptime` block that references every translated function: the stepping API (`swmm_open`,
  `swmm_step`, ...) and every helper are compiled and type-checked, but only the command line was gated.
- Speed: not benchmarked against EPA in one interleaved run (lessons/07).
- `realpath` here joins the working directory and the path and removes `.` and `..`; it does not resolve
  symbolic links as glibc's does. The corpus path has none.
- No person has reviewed the generated code line by line; the evidence is the gate, the checked build and the
  runtime check.

## Licence and credit

EPA SWMM is a work of the U.S. Environmental Protection Agency and is in the public domain; its engine is Lewis
Rossman's design, and this port keeps every algorithm as he wrote it. The port contains no glibc code: it calls
the system's glibc and libm (LGPL-2.1-or-later, `ref/LGPL-2.1.txt`) as shared libraries at run time, as EPA's
own build does. Zig's standard library (MIT) is compiled in. No licence has been chosen yet for the translator
and the runtime.

## AI use

The translator back end (`tools/c2x/emit_zig.py`), the runtime (`zig/src/rt.zig`, `zig/src/main.zig`), the
generated engine, the build and gate scripts, the runtime check and this README were written by Claude
(Anthropic's AI model, Claude Opus 5.5) in a Claude Code session on 6 November 2026, for Robert (Bob) Dickinson,
who chose Zig and Free Pascal as the next languages for his Code Rosetta Stone app and set the byte-for-byte
standard. Claude ran every build, gate and check reported here. The checks are mechanical; no person has yet
reviewed the code.
