#!/bin/sh
#
# Writes the files Tests/testdata/compiled/<name>.expected.applescript
# again from the current build. Run it only when a change to the output
# is wanted, then review the difference with
# `git diff Tests/testdata/compiled`.
#
# Three fixtures are decompiled with the `strings` pass, like the test
# that reads them does.

set -eu
cd "$(dirname "$0")/.."

swift build
TOOL=".build/debug/osatool"

for file in Tests/testdata/compiled/*.scpt; do
    name=$(basename "$file" .scpt)
    case "$name" in
        ascii_recovery | naive_list_edges | naive_empty_concat) pass="--pass strings" ;;
        *) pass="" ;;
    esac
    # shellcheck disable=SC2086
    "$TOOL" decompile --strict $pass "$file" > "Tests/testdata/compiled/$name.expected.applescript"
done
