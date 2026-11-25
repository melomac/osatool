#!/bin/sh
#
# Builds a libFuzzer target and runs it.
#
#   Scripts/fuzz.sh                      fuzz until stopped with Ctrl-C
#   Scripts/fuzz.sh -max_total_time=300  fuzz for 5 minutes
#   Scripts/fuzz.sh -fork=8 -ignore_crashes=1 -ignore_timeouts=1 -ignore_ooms=1
#                                        use 8 processes and go on after a finding
#   Scripts/fuzz.sh Fuzz/artifacts/crash-…   run one saved input again
#
# There are two targets. The first word chooses one:
#
#   Scripts/fuzz.sh scripts …       compiled scripts: disassemble and decompile
#                                   (the default, when the first word is no target)
#   Scripts/fuzz.sh terminology …   the files `osatool learn` reads: a saved
#                                   terminology file, a .sdef, a script suite
#
# Every other argument is given to libFuzzer as is (see `-help=1`).
#
# Folders (none of them in git):
#   Fuzz/corpus               inputs libFuzzer keeps between runs, for scripts
#   Fuzz/corpus-terminology   the same, for terminology
#   Fuzz/artifacts            inputs that crash, hang or use too much memory;
#                             the name of a terminology finding starts with
#                             `terminology-`
#
# Seeds are copied into the corpus at every start, so a new test file is
# fuzzed too: the sample scripts and the compiled probes of Tests/testdata,
# and for terminology some small files made here.
#
# libFuzzer is not part of Xcode's Swift. A swift.org toolchain is needed
# (for example one installed with swiftly).
#
# Set SANITIZE=fuzzer,address to also check memory errors (slower).

set -eu
cd "$(dirname "$0")/.."

TARGET=scripts
case "${1:-}" in
    scripts | terminology)
        TARGET=$1
        shift
        ;;
esac

SANITIZE="${SANITIZE:-fuzzer}"
BUILD=".build-fuzz"
if [ "$TARGET" = scripts ]; then
    PRODUCT=osatool-fuzz
    CORPUS=Fuzz/corpus
    DICTIONARY=Fuzz/osatool.dict
    PREFIX=Fuzz/artifacts/
    MAX_LEN=65536
else
    PRODUCT=osatool-fuzz-terminology
    CORPUS=Fuzz/corpus-terminology
    DICTIONARY=Fuzz/terminology.dict
    PREFIX=Fuzz/artifacts/terminology-
    MAX_LEN=16384
fi

OSATOOL_FUZZ=1 swift build -c release --product "$PRODUCT" --scratch-path "$BUILD" \
    -Xswiftc "-sanitize=$SANITIZE" -Xswiftc -g

FUZZER="$BUILD/release/$PRODUCT"
mkdir -p "$CORPUS" Fuzz/artifacts

# With a file argument, libFuzzer only runs that file: no corpus is needed.
for argument in "$@"; do
    if [ -f "$argument" ]; then
        exec "$FUZZER" -timeout=10 -rss_limit_mb=2048 "$@"
    fi
done

# Copies a seed into the corpus, unless a file of this name is there.
seed() {
    [ -e "$CORPUS/$2" ] || cp "$1" "$CORPUS/$2"
}

if [ "$TARGET" = scripts ]; then
    for file in Tests/testdata/*.scpt Tests/testdata/compiled/*.scpt; do
        seed "$file" "$(basename "$file")"
    done
    for file in Tests/testdata/backrefs/*.scpt; do
        seed "$file" "backrefs-$(basename "$file")"
    done
    for file in Tests/testdata/jxa/*.scpt; do
        seed "$file" "jxa-$(basename "$file")"
    done
    # The compiled probes are kept as base64 text, one after the other.
    WORK=$(mktemp -d)
    for file in Tests/testdata/probes/*.compiled.txt; do
        group=$(basename "$file" .compiled.txt)
        awk -v out="$WORK/probe-$group-" '
            /^--- / { if (name) close(name); count++; name = out count ".b64"; next }
            name { print > name }
        ' "$file"
    done
    for file in "$WORK"/*.b64; do
        name=$(basename "$file" .b64).scpt
        [ -e "$CORPUS/$name" ] || base64 -D -i "$file" -o "$CORPUS/$name"
    done
    rm -r "$WORK"
else
    # Small files of each kind, and what the tool itself writes from them.
    swift build --product osatool
    WORK=$(mktemp -d)
    cat > "$WORK/seed.sdef" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE dictionary SYSTEM "file://localhost/System/Library/DTDs/sdef.dtd">
<dictionary title="Seed" xmlns:xi="http://www.w3.org/2003/XInclude">
  <xi:include href="file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef" xpointer="xpointer(/dictionary/suite)"/>
  <suite name="Seed Suite" code="seeD">
    <record-type name="polish reply" code="plrp">
      <property name="shine" code="shin" type="integer"/>
    </record-type>
    <value-type name="specifier" code="obj "/>
    <enumeration name="save options" code="savo">
      <enumerator name="yes" code="yes "/>
      <enumerator name="no" code="no  "/>
    </enumeration>
    <command name="polish" code="seeDplsh">
      <direct-parameter type="specifier"/>
      <parameter name="with" code="with" type="text" optional="yes"/>
      <parameter name="quickly" code="quik" type="boolean"/>
    </command>
    <class name="gadget" code="gdgt" plural="gadgets">
      <property name="name" code="pnam" type="text"><synonym code="pnm2"/></property>
      <element type="widget"/>
      <contents name="contents" code="pcnt" type="text"/>
    </class>
    <class-extension extends="application">
      <property name="frontmost" code="pisf" type="boolean" access="r"/>
    </class-extension>
  </suite>
</dictionary>
EOF
    cat > "$WORK/seed.scriptSuite" <<'EOF'
{
    "Name" = "Seed";
    "AppleEventCode" = "seeD";
    "Classes" = { "Gadget" = { "AppleEventCode" = "gdgt"; "Attributes" = { "title" = { "AppleEventCode" = "titl"; "Type" = "NSString"; }; }; }; };
    "Commands" = { "Polish" = { "AppleEventClassCode" = "seeD"; "AppleEventCode" = "plsh"; "Arguments" = { "Quickly" = { "AppleEventCode" = "quik"; "Type" = "NSNumber<Bool>"; }; }; }; };
    "Enumerations" = { "Shade" = { "AppleEventCode" = "shad"; "Enumerators" = { "Dark" = "dark"; }; }; };
}
EOF
    cat > "$WORK/seed.scriptTerminology" <<'EOF'
{
    "Classes" = { "Gadget" = { "Name" = "gadget"; "PluralName" = "gadgets"; "Attributes" = { "title" = { "Name" = "title"; }; }; }; };
    "Commands" = { "Polish" = { "Name" = "polish"; "Arguments" = { "Quickly" = { "Name" = "quickly"; }; }; }; };
    "Enumerations" = { "Shade" = { "Dark" = { "Name" = "dark"; }; }; };
}
EOF
    cat > "$WORK/seed-language.json" <<'EOF'
{ "schema_version": 1, "source": "seed",
  "commands": [{ "code": "aevtquit", "name": "quit", "has_direct_parameter": true, "parameters": [{ "code": "savo", "name": "saving", "type": "savo" }] }],
  "terms": [{ "code": "pnam", "name": "name" }],
  "enumerations": [{ "group": "savo", "code": "yes ", "name": "yes" }],
  "reserved_words": ["repeat", "end"] }
EOF
    TOOL=.build/debug/osatool
    "$TOOL" learn --output "$WORK/seed-store.json" "$WORK/seed.sdef" "$WORK/seed.scriptSuite" "$WORK/seed-language.json" > /dev/null
    "$TOOL" learn --compact --output "$WORK/seed-store-compact.json" "$WORK/seed-store.json" > /dev/null
    "$TOOL" learn --compact --compress --output "$WORK/seed-store.sref" "$WORK/seed-store.json" > /dev/null
    plutil -convert binary1 -o "$WORK/seed-binary.scriptSuite" "$WORK/seed.scriptSuite"
    plutil -convert xml1 -o "$WORK/seed-xml.scriptTerminology" "$WORK/seed.scriptTerminology"
    for file in "$WORK"/seed*; do
        seed "$file" "$(basename "$file")"
    done
    rm -r "$WORK"
fi

exec "$FUZZER" \
    -dict="$DICTIONARY" \
    -artifact_prefix="$PREFIX" \
    -max_len="$MAX_LEN" \
    -timeout=10 \
    -rss_limit_mb=2048 \
    "$@" \
    "$CORPUS"
