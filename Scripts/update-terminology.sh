#!/bin/sh
#
# Makes the built-in terminology again from the files of this system.
#
#   Scripts/update-terminology.sh
#
# Terminology/sources.txt lists the scripting definitions of
# well-known Apple software, one path on each line. The tool itself reads
# them (`osatool learn`) and writes
# Terminology/applications.json. Then
# Scripts/embed-terminology.sh makes the file that is linked into the
# next build.
#
# A file of the list that is not on this system is reported and left out.
# Run the tests after this script: a new system can change the name of a
# term, and with it some expected output.
#
# A few words of Standard Additions do not compile back to their code
# (see Scripts/compiler-words.py). That script takes them out again. It
# calls osacompile, so it runs here only with OSATOOL_APPLE_TOOLS set:
#
#   OSATOOL_APPLE_TOOLS=1 Scripts/update-terminology.sh

set -eu
cd "$(dirname "$0")/.."

swift build --product osatool
tr '\n' '\0' < Terminology/sources.txt \
    | xargs -0 .build/debug/osatool learn --output Terminology/applications.json
if [ -n "${OSATOOL_APPLE_TOOLS:-}" ]; then
    WORK=$(mktemp -d)
    python3 Scripts/compiler-words.py Terminology/language.json Terminology/applications.json \
        "$WORK" .build/debug/osatool --write | tail -6
    rm -r "$WORK"
else
    echo "update-terminology.sh: OSATOOL_APPLE_TOOLS is not set, so Scripts/compiler-words.py was not run" >&2
fi
Scripts/embed-terminology.sh
