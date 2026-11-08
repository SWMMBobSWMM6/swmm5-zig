# AI use

This repository was made with Claude, Anthropic's AI model (Claude Opus 5.5), in Claude Code sessions on
6 to 8 November 2026, under the direction of Robert (Bob) Dickinson. He found that his Code Rosetta Stone app held
no genuinely translated, working SWMM5 engines beyond the ones made in these sessions, chose the languages (Zig,
Free Pascal, Kotlin, and Scala, which he replaced with Ruby when this sandbox could not fetch or run a Scala
compiler), asked that each be checked byte for byte against EPA SWMM 5.2.4 as the earlier six ports were, created
this repository and supplied the model corpus. Responsibility for publishing the work is his.

**What Claude did.** It wrote the Zig back end of the translator (`tools/c2x/emit_zig.py`; the libclang
front end `tools/c2x/front.py` was written earlier for the first six ports), the hand-written runtime that gives the
C library's behaviour (printf, sscanf, strtod, file I/O and the rest), the build and gate scripts, ran
every test, diagnosed and fixed every mismatch, and wrote the README and the lessons. Claude subagents did the
translation; the main session then re-ran the whole gate on its own (gate run `zig_v`, 480 of 480 identical) before publishing.

**How the results were checked.** Mechanically: byte comparison of every `.out` and `.rpt` with EPA 5.2.4 built from
its tag on the 480 gate models, and the runtime compared with glibc directly (lesson 25 is why: a gate can pass
with a runtime that is wrong on inputs the corpus never gives it). No person has yet reviewed the generated code or
the runtime line by line, or rerun the gate on another machine.

`gate/savefiles.py`, which lists the files a deck SAVEs so the gate can restore them, comes from the swmm6-rust
repository (also written by Claude for Bob).
