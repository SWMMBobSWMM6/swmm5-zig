#!/bin/bash
# runswmm_saves.sh - the Zig engine (bin/runswmm) for gate/gate.py, which runs
# `ENGINE model.inp report.rpt output.out` in the model's folder. The files the deck SAVEs to ([FILES], listed
# by savefiles.py from the swmm6-rust repository, called read-only) are backed up first and restored after, so
# a SAVE in the corpus never changes a file another deck USEs. The exit status is the engine's.
# SWMM_BIN overrides the engine; SAVEFILES the lister; TMPDIR where the backups go.
H=$(cd "$(dirname "$0")" && pwd)
BIN=${SWMM_BIN:-$H/bin/runswmm}
SAVEFILES=${SAVEFILES:-$H/../gate/savefiles.py}
d="$PWD/$1"
B=$(mktemp -d "${TMPDIR:-/tmp}/swmmsave.XXXXXX"); python3 "$SAVEFILES" "$d" > "$B/saves.txt" 2>/dev/null; k=0
while IFS= read -r f; do k=$((k+1)); [ -f "$f" ] && cp -p "$f" "$B/$k"; done < "$B/saves.txt"
"$BIN" "$@"; rc=$?
k=0; while IFS= read -r f; do k=$((k+1)); if [ -f "$B/$k" ]; then cp -p "$B/$k" "$f"; else rm -f "$f"; fi; done < "$B/saves.txt"
rm -rf "$B"; exit $rc
