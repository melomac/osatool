#!/bin/sh
#
# Makes the terminology that is linked into the tool again:
# Terminology/terminology.sref.
#
#   Scripts/embed-terminology.sh
#
# Run it after a change to one of the two files that people read:
#
#   Terminology/language.json       the words of the language
#   Terminology/applications.json   the words of applications
#
# The tool itself reads the two files (`osatool learn`) and writes them
# as one file: JSON on one line, as a zlib stream. The linker copies that
# file into the section (__DATA_CONST,__sref) of the next build. A test fails
# while the file does not hold what the two JSON files hold.

set -eu
cd "$(dirname "$0")/.."

swift build --product osatool
.build/debug/osatool learn --compact --compress \
    --output Terminology/terminology.sref \
    Terminology/language.json \
    Terminology/applications.json \
    | tail -1
swift build --product osatool
