#!/bin/sh
#
# Writes the files in Tests/testdata/snapshots again from the current
# build. Run it only when a change to the output is wanted, then review
# the difference with `git diff Tests/testdata/snapshots`.

set -eu
cd "$(dirname "$0")/.."

swift build
TOOL=".build/debug/osatool"
OUT="Tests/testdata/snapshots"

for file in Tests/testdata/compiled/*.scpt Tests/testdata/demo.scpt Tests/testdata/seccon.scpt; do
    name=$(basename "$file" .scpt)
    "$TOOL" disassemble --builtin-terminology "$file" > "$OUT/$name.disasm.txt" 2>/dev/null
    "$TOOL" disassemble --builtin-terminology --json "$file" > "$OUT/$name.disasm.json" 2>/dev/null
done
for name in demo seccon; do
    "$TOOL" decompile "Tests/testdata/$name.scpt" > "$OUT/$name.applescript" 2>/dev/null
    "$TOOL" decompile --pass strings "Tests/testdata/$name.scpt" > "$OUT/$name.strings.applescript" 2>/dev/null
done
"$TOOL" decompile --no-unwrap Tests/testdata/seccon.scpt > "$OUT/seccon.wrapped.applescript" 2>/dev/null
