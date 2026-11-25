#!/bin/sh
#
# Writes the compiled form and the expected source of the probes again:
# Tests/testdata/probes/<group>.compiled.txt and <group>.expected.txt.
#
# Run it after a change to a probe file, or when a change to the output
# is wanted. Review the difference with `git diff Tests/testdata/probes`.
#
# It calls `osacompile`, which can start an application to read its
# dictionary: the probes tell the Finder, System Events, Mail, Safari,
# Terminal and TextEdit. So it works only with OSATOOL_APPLE_TOOLS set,
# like the tests that call Apple's tools:
#
#   OSATOOL_APPLE_TOOLS=1 Scripts/update-probes.sh

set -eu
cd "$(dirname "$0")/.."

if [ -z "${OSATOOL_APPLE_TOOLS:-}" ]; then
    echo "update-probes.sh: set OSATOOL_APPLE_TOOLS=1 to let osacompile run" >&2
    exit 1
fi

OSATOOL_WRITE_PROBES=1 swift test --filter "write the compiled probes"
