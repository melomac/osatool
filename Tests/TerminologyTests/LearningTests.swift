import Extensions
import Foundation
import Terminology
import Testing

/** Tests of what `osatool learn` is built on: script suites, the scanner and the store. */

private let suite = """
{
    "Name" = "Thing";
    "AppleEventCode" = "thng";
    "Classes" = {
        "Widget" = {
            "AppleEventCode" = "wdgt";
            "Attributes" = {
                "weight" = { "AppleEventCode" = "wght"; "Type" = "NSNumber"; };
                "secret" = { "AppleEventCode" = "scrt"; "Type" = "NSString"; };
            };
            "ToManyRelationships" = {
                "parts" = { "AppleEventCode" = "part"; "Type" = "Part"; };
            };
        };
    };
    "Commands" = {
        "Polish" = {
            "AppleEventClassCode" = "thng";
            "AppleEventCode" = "plsh";
            "UnnamedArgument" = { "Type" = "NSObject"; };
            "Arguments" = {
                "Quickly" = { "AppleEventCode" = "quik"; "Type" = "NSNumber<Bool>"; "Optional" = "YES"; };
                "With" = { "AppleEventCode" = "with"; "Type" = "NSString"; };
            };
        };
        "Hidden" = { "AppleEventClassCode" = "thng"; "AppleEventCode" = "hidn"; };
    };
    "Enumerations" = {
        "Finish" = {
            "AppleEventCode" = "fnsh";
            "Enumerators" = { "Matte" = "matt"; "Glossy" = "glos"; };
        };
    };
}
"""

private let terminology = """
{
    "Name" = "Thing suite";
    "Classes" = {
        "Widget" = {
            "Name" = "widget";
            "PluralName" = "widgets";
            "Attributes" = { "weight" = { "Name" = "weight"; }; };
            "ToManyRelationships" = { "parts" = { "Name" = "part"; }; };
        };
    };
    "Commands" = {
        "Polish" = {
            "Name" = "polish";
            "Arguments" = {
                "Quickly" = { "Name" = "quickly"; };
                "With" = { "Name" = "with cloth"; };
            };
        };
    };
    "Enumerations" = {
        "Finish" = { "Matte" = { "Name" = "matte"; }; "Glossy" = { "Name" = "glossy"; }; };
    };
    "Synonyms" = {
        "slce" = { "Name" = "slice"; "PluralName" = "slices"; };
        "wdgt" = { "Name" = "other widget"; };
        "toolong" = { "Name" = "bad code"; };
    };
}
"""

private let definition = """
<?xml version="1.0" encoding="UTF-8"?>
<dictionary>
    <suite name="Thing" code="thng">
        <class name="gadget" code="gdgt"/>
        <class name="first widget name" code="wdgt"/>
    </suite>
</dictionary>
"""

@Test func `script suite joins codes and names`() throws {
    let dictionary = try parseScriptSuite(name: "Thing", suite: Data(suite.utf8), terminology: Data(terminology.utf8))

    #expect(try dictionary.terms[Code4(parsing: "wdgt")] == "widget")
    #expect(try dictionary.terms[Code4(parsing: "wght")] == "weight")
    #expect(try dictionary.terms[Code4(parsing: "part")] == "part")
    // An attribute with no name in the terminology file is left out.
    #expect(try dictionary.terms[Code4(parsing: "scrt")] == nil)

    let polish = try #require(try dictionary.commands[EventCode(parsing: "thngplsh")])
    #expect(polish.name == "polish")
    #expect(polish.hasDirectParameter)
    #expect(try polish.parameterOrder == [Code4(parsing: "quik"), Code4(parsing: "with")])
    #expect(try polish.parameters[Code4(parsing: "quik")]?.type == "boolean")
    #expect(try polish.parameters[Code4(parsing: "with")]?.name == "with cloth")
    // A command with no name in the terminology file is left out.
    #expect(try dictionary.commands[EventCode(parsing: "thnghidn")] == nil)

    #expect(try dictionary.enums[Code4(parsing: "matt")] == "matte")
    #expect(try dictionary.constants[EventCode(parsing: "fnshglos")] == "glossy")

    // A class named by its code only, as `paragraph` is in the text suite of Cocoa.
    #expect(dictionary.terms["slce"] == "slice" && dictionary.plurals["slce"] == "slices")
    // The name of a class of the suite stays.
    #expect(dictionary.terms["wdgt"] == "widget")
    #expect(dictionary.terms.count == 4)
}

@Test func `script suite rejects a file that is not a property list`() {
    #expect(throws: (any Error).self) {
        try parseScriptSuite(name: "Bad", suite: Data("<<<".utf8), terminology: Data(terminology.utf8))
    }
}

@Test func `code text reads back`() throws {
    let cases: [[UInt8]] = [Array("pnam".utf8), [0x63, 0x61, 0x66, 0x8e], [0x61, 0x00, 0x62, 0x63], Array("0x12".utf8), Array("to  ".utf8)]
    for bytes in cases {
        let code = Code4(bytes: bytes)
        #expect(try Code4(parsing: code.text) == code, "\(bytes)")
    }
    #expect(Code4(bytes: [0x61, 0x00, 0x62, 0x63]).text == "0x61006263")
    let event = EventCode(bytes: Array("aevtoapp".utf8))
    #expect(event.text == "aevtoapp")
    #expect(try EventCode(parsing: event.text) == event)
}

@Test func `store reads back what it writes`() throws {
    var dictionary = try parseScriptSuite(name: "Thing \"quoted\"", suite: Data(suite.utf8), terminology: Data(terminology.utf8))
    dictionary.sources = ["/tmp/Thing.scriptSuite", "/tmp/Thing.scriptTerminology"]
    let store = TerminologyStore(system: "test system", dictionaries: [dictionary])
    let written = store.data()
    let read = try TerminologyStore(data: written)

    #expect(read.system == "test system")
    #expect(read.dictionaries.count == 1)
    let copy = try #require(read.dictionaries.first)
    #expect(copy.name == dictionary.name)
    #expect(copy.sources == dictionary.sources)
    #expect(copy.terms == dictionary.terms)
    #expect(copy.enums == dictionary.enums)
    #expect(copy.constants == dictionary.constants)
    #expect(copy.bundleID.isEmpty && !String(decoding: written, as: UTF8.self).contains("\"id\""))
    let polish = try #require(try copy.commands[EventCode(parsing: "thngplsh")])
    #expect(polish.hasDirectParameter)
    #expect(try polish.parameterOrder == [Code4(parsing: "quik"), Code4(parsing: "with")])
    #expect(try polish.parameters[Code4(parsing: "quik")]?.type == "boolean")
    // Writing the copy gives the same bytes: the layout is stable.
    #expect(read.data() == written)
}

/** The folder of the two terminology files that people read: they are not in the program. */
private let terminologyFiles = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Terminology")

/**
 The dictionaries of applications are a file that the tool wrote:
 reading the file and writing it again gives the same bytes. So a new
 version of the file, made by `Scripts/update-terminology.sh`, differs
 from the old one only where the terminology differs.
 */
@Test func `the file of applications is in the layout the store writes`() throws {
    let file = try Data(contentsOf: terminologyFiles.appendingPathComponent("applications.json"))
    #expect(try TerminologyStore(data: file).data() == file)
}

/** The linker put the terminology in the test program too: a zlib stream in its own section. */
@Test func `the program has its terminology in a section`() throws {
    let section = try #require(BundledTerminology.store)
    #expect(section.isZlibStream)
    #expect(Data(machOSection: "__nothing", segment: BundledTerminology.segment) == nil)
    let store = try TerminologyStore(data: section)
    #expect(store.dictionaries.contains { $0.name == languageDictionaryName })
    #expect(store.dictionaries.contains { $0.name == "StandardAdditions" })
}

/**
 The section holds what the two JSON files hold. When one of them
 changes, `Scripts/embed-terminology.sh` must be run: this test fails
 until it is.
 */
@Test func `the terminology in the program is made from the two files`() throws {
    let scan = scanTerminology(paths: ["language.json", "applications.json"].map { terminologyFiles.appendingPathComponent($0).path })
    #expect(scan.problems.isEmpty, "\(scan.problems)")
    var fromFiles = TerminologyStore()
    fromFiles.replace(with: scan.dictionaries)
    var inProgram = try TerminologyStore(data: #require(BundledTerminology.store))
    inProgram.system = ""
    #expect(inProgram.data() == fromFiles.data(), "run Scripts/embed-terminology.sh")
}

/** A store is read from its three forms, and the language keeps its reserved words. */
@Test func `store reads its compact and compressed forms`() throws {
    var dictionary = try parseScriptSuite(name: "Thing", suite: Data(suite.utf8), terminology: Data(terminology.utf8))
    dictionary.reservedWords = ["repeat", "end"]
    let store = TerminologyStore(system: "test system", dictionaries: [dictionary])
    let readable = store.data()
    let compact = store.data(compact: true)
    let compressed = try compact.zlibCompressed()

    #expect(compact.count < readable.count)
    #expect(compact.filter { $0 == UInt8(ascii: "\n") }.count == 1)
    #expect(String(decoding: compact, as: UTF8.self).hasPrefix(#"{"schema_version":1,"system":"test system","dictionaries":[{"name":"Thing","#))
    #expect(String(decoding: readable, as: UTF8.self).contains("""
          "reserved_words": [
            "end",
            "repeat"
          ]
    """))
    for form in [readable, compact, compressed] {
        let read = try TerminologyStore(data: form)
        #expect(read.data() == readable)
        #expect(read.dictionaries.first?.reservedWords == ["repeat", "end"])
    }
}

@Test func `zlib streams`() throws {
    // The checksum of the text "Wikipedia" is a known value.
    #expect(Data("Wikipedia".utf8).adler32 == 0x11e6_0398)
    #expect(Data().adler32 == 1)

    let text = Data(String(repeating: "the same words again and again. ", count: 200).utf8)
    let stream = try text.zlibCompressed()
    #expect(stream.isZlibStream)
    #expect(stream.prefix(2) == Data([0x78, 0x9c]))
    #expect(stream.count < text.count / 10)
    #expect(try stream.zlibDecompressed() == text)
    #expect(try Data().zlibCompressed().zlibDecompressed() == Data())

    #expect(!text.isZlibStream)
    #expect(!Data(#"{ "schema_version": 1 }"#.utf8).isZlibStream)
    #expect(throws: (any Error).self) { try text.zlibDecompressed() }
    var damaged = stream
    damaged[damaged.count - 1] ^= 0xff
    #expect(throws: (any Error).self) { try damaged.zlibDecompressed() }
    #expect(throws: (any Error).self) { try TerminologyStore(data: damaged) }

    // A stream that is cut, with a header and four last bytes left.
    let cut = stream.prefix(stream.count / 2) + stream.suffix(4)
    #expect(throws: (any Error).self) { try cut.zlibDecompressed() }
    #expect(throws: (any Error).self) { try Data([0x78, 0x9c, 0, 0, 0, 1]).zlibDecompressed() }
}

/**
 A small stream can expand to a very large size. The expansion stops at
 a limit, before the memory is used.
 */
@Test func `a zlib stream that expands too much is refused`() throws {
    // Ten megabytes of zeros are a stream of about ten kilobytes.
    let zeros = Data(count: 10 * 1024 * 1024)
    let stream = try zeros.zlibCompressed()
    #expect(stream.count < zeros.count / 500)
    #expect(try stream.zlibDecompressed() == zeros)
    #expect(try stream.zlibDecompressed(limit: zeros.count) == zeros)
    let error = #expect(throws: ScriptError.self) { try stream.zlibDecompressed(limit: zeros.count - 1) }
    #expect(error?.message == "expand: the data is larger than \(zeros.count - 1) bytes")
    #expect(throws: ScriptError.self) { try stream.zlibDecompressed(limit: 0) }
    // The limit of the tool is above what its own terminology needs.
    #expect(maximumExpandedSize >= 16 * 1024 * 1024)
}

/**
 A file that was saved before is read like an application: a store
 gives its dictionaries, and the language file gives the dictionary of
 the language. Such a file is read only when it is named.
 */
@Test func `scan reads a saved file and the language file`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let thing = try parseScriptSuite(name: "Thing", suite: Data(suite.utf8), terminology: Data(terminology.utf8))
    let saved = root.appendingPathComponent("saved.json")
    let compressed = root.appendingPathComponent("saved.sref")
    try TerminologyStore(dictionaries: [thing]).data().write(to: saved)
    try TerminologyStore(dictionaries: [thing]).data(compact: true).zlibCompressed().write(to: compressed)
    let language = root.appendingPathComponent("language.json")
    try Data(#"{ "schema_version": 1, "terms": [{ "code": "pnam", "name": "name" }], "reserved_words": ["Repeat"] }"#.utf8).write(to: language)
    let broken = root.appendingPathComponent("broken.json")
    try Data("{".utf8).write(to: broken)

    let result = scanTerminology(paths: [saved.path, language.path, broken.path])
    #expect(result.dictionaries.map(\.name) == [languageDictionaryName, "Thing"])
    #expect(result.dictionaries.first?.reservedWords == ["repeat"])
    #expect(try result.dictionaries.last?.commands[EventCode(parsing: "thngplsh")]?.name == "polish")
    #expect(result.problems.count == 1)
    #expect(result.problems.first?.contains("broken.json") == true)

    // A compressed file has no extension the scan knows: it is read when named, whatever its name.
    #expect(scanTerminology(paths: [compressed.path]).dictionaries.map(\.name) == ["Thing"])
    // A folder is not searched for saved files.
    let found = scanTerminology(paths: [root.path])
    #expect(found.dictionaries.isEmpty)
    #expect(found.problems.isEmpty)
}

@Test func `store rejects another schema version and bad codes`() {
    #expect(throws: (any Error).self) {
        try TerminologyStore(data: Data(#"{ "schema_version": 99, "dictionaries": [] }"#.utf8))
    }
    #expect(throws: (any Error).self) {
        try TerminologyStore(data: Data(#"{ "schema_version": 1, "dictionaries": [{ "name": "X", "terms": [{ "code": "toolong", "name": "x" }] }] }"#.utf8))
    }
}

@Test func `a learned dictionary replaces the one with the same name`() {
    var store = TerminologyStore(dictionaries: [
        ScriptingDictionary(name: "B", terms: [Code4(bytes: Array("aaaa".utf8)): "old"]),
        ScriptingDictionary(name: "A"),
    ])
    store.replace(with: [ScriptingDictionary(name: "B", terms: [Code4(bytes: Array("aaaa".utf8)): "new"]), ScriptingDictionary(name: "C")])
    #expect(store.dictionaries.map(\.name) == ["A", "B", "C"])
    #expect(store.dictionaries[1].terms[Code4(bytes: Array("aaaa".utf8))] == "new")
}

/** The identifier of an application is kept in the file, after the name. */
@Test func `store keeps the identifier of an application`() throws {
    var dictionary = ScriptingDictionary(name: "Finder", terms: ["brow": "Finder window"])
    dictionary.bundleID = "com.apple.finder"
    let written = TerminologyStore(dictionaries: [dictionary]).data()
    #expect(String(decoding: written, as: UTF8.self).contains(#""name": "Finder",\#n      "id": "com.apple.finder""#))
    #expect(try TerminologyStore(data: written).dictionaries.first?.bundleID == "com.apple.finder")
}

/**
 An SDEF file can include another one, and the application has an
 identifier in its `Info.plist`:

 ```
 root/Thing.app/Contents/Info.plist                  com.example.thing
 root/Thing.app/Contents/Resources/Thing.sdef        includes Shared.sdef, Thing.sdef, a web address, a text file
 root/Thing.app/Contents/Resources/Shared.sdef       includes Thing.sdef
 ```
 */
@Test func `scan reads the included files and the identifier of the application`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-include-\(UUID().uuidString)")
    let contents = root.appendingPathComponent("Thing.app/Contents")
    let resources = contents.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.thing</string></dict></plist>"#.utf8)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let shared = resources.appendingPathComponent("Shared.sdef")
    try Data("""
    <dictionary xmlns:xi="http://www.w3.org/2003/XInclude">
      <suite name="Thing" code="thng">
        <class name="widget" code="wdgt"/>
        <xi:include href="Shared.sdef"/>
        <xi:include href="\(URL(fileURLWithPath: shared.path).absoluteString)"/>
        <xi:include href="Thing.sdef"/>
        <xi:include href="https://example.com/Other.sdef"/>
        <xi:include href="notes.txt"/>
        <xi:include href="Missing.sdef"/>
      </suite>
    </dictionary>
    """.utf8).write(to: resources.appendingPathComponent("Thing.sdef"))
    try Data("""
    <dictionary xmlns:xi="http://www.w3.org/2003/XInclude">
      <xi:include href="Thing.sdef"/>
      <suite name="Shared" code="shrd"><class name="other widget" code="wdgt"/><class name="window" code="cwin"/></suite>
    </dictionary>
    """.utf8).write(to: shared)
    try Data("not a definition".utf8).write(to: resources.appendingPathComponent("notes.txt"))

    let result = scanTerminology(paths: [resources.appendingPathComponent("Thing.sdef").path])

    let thing = try #require(result.dictionaries.first)
    #expect(result.dictionaries.count == 1 && thing.name == "Thing")
    #expect(thing.bundleID == "com.example.thing")
    // The words of the file itself come first, then those of the file it includes.
    #expect(thing.terms["wdgt"] == "widget" && thing.terms["cwin"] == "window")
    #expect(thing.sources.map { ($0 as NSString).lastPathComponent } == ["Thing.sdef", "Shared.sdef"])
    // What is not an `.sdef` file on this computer is not read.
    #expect(result.problems.count == 3)
    for name in ["https://example.com/Other.sdef", "notes.txt", "Missing.sdef"] {
        #expect(result.problems.contains { $0.contains(name) && $0.contains("is not read") }, "\(name)")
    }

    // A folder, a file outside an application, a file that is not there.
    #expect("/System/Library/ScriptingDefinitions/CocoaStandard.sdef".applicationInfo.identifier.isEmpty)
    #expect("/nonexistent/Thing.app/Contents/Resources/Thing.sdef".applicationInfo.identifier.isEmpty)
    #expect((root.path + "/Thing.app/Contents/Resources/Plug.osax/Contents/Resources/Plug.sdef").applicationInfo.identifier.isEmpty)
    #expect((resources.path + "/Thing.sdef").applicationInfo == ("com.example.thing", ""))
    #expect("/dev/zero".includedDefinitionPath(from: "/tmp/a.sdef") == nil)
    #expect("file://example.com/tmp/a.sdef".includedDefinitionPath(from: "/tmp/a.sdef") == nil)
    #expect(root.path.includedDefinitionPath(from: "/tmp/a.sdef") == nil)
}

/**
 An application that names its scripting definition in `Info.plist` is
 described by that file only. The system does not read the script
 suites such an application still has, and neither does the scan.

 ```
 root/New.app   Info.plist names New.sdef    New.sdef, Old.scriptSuite + Old.scriptTerminology
 root/Old.app   Info.plist names nothing     Old.scriptSuite + Old.scriptTerminology
 ```
 */
@Test func `scan leaves out the script suites of an application with a scripting definition`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-key-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, key) in [("New", "<key>OSAScriptingDefinition</key><string>New.sdef</string>"), ("Old", "")] {
        let contents = root.appendingPathComponent("\(name).app/Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("<plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.example.\(name)</string>\(key)</dict></plist>".utf8)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(suite.utf8).write(to: resources.appendingPathComponent("Old.scriptSuite"))
        try Data(terminology.utf8).write(to: resources.appendingPathComponent("Old.scriptTerminology"))
        if name == "New" {
            try Data(definition.utf8).write(to: resources.appendingPathComponent("New.sdef"))
        }
    }

    let result = scanTerminology(paths: [root.path])

    #expect(result.problems.isEmpty)
    #expect(result.dictionaries.map(\.name) == ["New", "Old"])
    let new = result.dictionaries[0]
    #expect(new.bundleID == "com.example.New" && new.sources.map { ($0 as NSString).lastPathComponent } == ["New.sdef"])
    // `gadget` is a word of the definition; `weight` is a word of the suite only.
    #expect(new.terms["gdgt"] == "gadget" && new.terms["wght"] == nil)
    let old = result.dictionaries[1]
    #expect(old.bundleID == "com.example.Old" && old.terms["wght"] == "weight")
    #expect((root.path + "/New.app/Contents/Resources/Old.scriptSuite").applicationInfo == ("com.example.New", "New.sdef"))
}

/**
 A scan reads files that anyone could have made. A link to a device
 that never ends, a folder with the name of a file, and a file that is
 too large are reported, and not read.
 */
@Test func `scan reads only files of a sane size`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-size-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder.sdef"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Endless.sdef").path, withDestinationPath: "/dev/zero")
    try Data(definition.utf8).write(to: root.appendingPathComponent("Good.sdef"))
    // A file with a hole: it takes no room on the disk.
    let large = root.appendingPathComponent("Large.sdef")
    try Data().write(to: large)
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(maximumDefinitionSize) + 1)
    try handle.close()

    let paths = ["Endless.sdef", "Folder.sdef", "Good.sdef", "Large.sdef"].map { root.appendingPathComponent($0).path }
    #expect(throws: ScriptError.self) { try paths[0].definitionFileData() }
    #expect(throws: ScriptError.self) { try paths[1].definitionFileData() }
    #expect(try paths[2].definitionFileData() == Data(definition.utf8))
    #expect(throws: ScriptError.self) { try paths[3].definitionFileData() }
    #expect(throws: ScriptError.self) { try (root.path + "/Missing.sdef").definitionFileData() }

    // Each one named as a file: a folder that is named is searched, and holds nothing.
    let result = scanTerminology(paths: paths)
    #expect(result.dictionaries.map(\.name) == ["Good"])
    #expect(result.problems.count == 2)
    #expect(result.problems.contains { $0.contains("Endless.sdef") && $0.contains("not a file") })
    #expect(result.problems.contains { $0.contains("Large.sdef") && $0.contains("larger than") })
}

@Test func `a dictionary is named after the innermost bundle`() {
    let cases: [(String, String)] = [
        ("/Applications/Keynote.app/Contents/Resources/Keynote.sdef", "Keynote"),
        ("/Applications/Xcode.app/Contents/Applications/Instruments.app/Contents/Resources/Instruments.sdef", "Instruments"),
        ("/System/Applications/Calendar.app/Contents/Resources/iCal.sdef", "Calendar"),
        ("/System/Library/ScriptingAdditions/StandardAdditions.osax/Contents/Resources/StandardAdditions.sdef", "StandardAdditions"),
        ("/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/OpenScripting.framework/Versions/A/Resources/Compatibility.sdef", "OpenScripting"),
        ("/System/Library/PreferencePanes/Network.prefPane/Contents/Resources/Network.scripting/Contents/Resources/NetworkPref.scriptSuite", "Network"),
        ("/System/Library/ScriptingDefinitions/CocoaStandard.sdef", "CocoaStandard"),
        // The words every application has are a dictionary of their own.
        ("/System/Library/Frameworks/Foundation.framework/Versions/C/Resources/Intrinsics.sdef", "Intrinsics"),
        ("/System/Library/Frameworks/Foundation.framework/Versions/C/Resources/NSCoreSuite.scriptSuite", "Foundation"),
        ("/System/Library/Frameworks/ScriptingBridge.framework/Versions/A/Resources/intrinsics.sdef", "ScriptingBridge"),
        ("Thing.sdef", "Thing"),
    ]
    for (path, want) in cases {
        #expect(path.dictionaryName == want, "\(path)")
    }
}

/**
 A folder with one application that has an SDEF file and a script suite,
 and one script suite with no terminology file next to it.
 */
@Test func `scan reads a folder and groups files by application`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-scan-\(UUID().uuidString)")
    let resources = root.appendingPathComponent("Deep/Thing.app/Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(definition.utf8).write(to: resources.appendingPathComponent("Thing.sdef"))
    try Data(suite.utf8).write(to: resources.appendingPathComponent("Extra.scriptSuite"))
    try Data(terminology.utf8).write(to: resources.appendingPathComponent("Extra.scriptTerminology"))
    try Data(suite.utf8).write(to: root.appendingPathComponent("Orphan.scriptSuite"))
    // A file of another kind inside a folder is not looked at.
    try Data("not a definition".utf8).write(to: root.appendingPathComponent("notes.txt"))

    let result = scanTerminology(paths: [root.path, "/nonexistent/osatool-test"])

    #expect(result.dictionaries.map(\.name) == ["Thing"])
    let thing = try #require(result.dictionaries.first)
    #expect(thing.sources.count == 3)
    // A path is reported as the user wrote it: the given folder, then the part below it.
    #expect(thing.sources.first == root.path + "/Deep/Thing.app/Contents/Resources/Thing.sdef")
    #expect(try thing.terms[Code4(parsing: "gdgt")] == "gadget")
    // The SDEF file is read first, so its name for 'wdgt' stays.
    #expect(try thing.terms[Code4(parsing: "wdgt")] == "first widget name")
    #expect(try thing.commands[EventCode(parsing: "thngplsh")]?.name == "polish")

    #expect(result.problems.count == 2)
    #expect(result.problems.contains { $0.contains("Orphan.scriptSuite") && $0.contains("no .scriptTerminology") })
    #expect(result.problems.contains { $0.contains("/nonexistent/osatool-test") })
}

/**
 `/Applications/Safari.app` is a symbolic link to a folder on another
 volume. A scan of the parent folder must follow such a link, but not a
 link whose target is searched anyway.

 ```
 root/Apps/Linked.app  ──▶  root/Elsewhere/Real.app      followed
 root/Apps/Inside      ──▶  root/Apps/Own.app            not followed
 root/Elsewhere/Real.app/Back  ──▶  root/Apps            not followed (a loop)
 ```
 */
@Test func `scan follows a link that leads out of the folder`() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("osatool-links-\(UUID().uuidString)")
    let apps = root.appendingPathComponent("Apps")
    let real = root.appendingPathComponent("Elsewhere/Real.app")
    let own = apps.appendingPathComponent("Own.app")
    try manager.createDirectory(at: real, withIntermediateDirectories: true)
    try manager.createDirectory(at: own, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    try Data(definition.utf8).write(to: real.appendingPathComponent("Real.sdef"))
    try Data(definition.utf8).write(to: own.appendingPathComponent("Own.sdef"))
    try manager.createSymbolicLink(at: apps.appendingPathComponent("Linked.app"), withDestinationURL: real)
    try manager.createSymbolicLink(at: apps.appendingPathComponent("Inside"), withDestinationURL: own)
    try manager.createSymbolicLink(at: real.appendingPathComponent("Back"), withDestinationURL: apps)

    let result = scanTerminology(paths: [apps.path])

    // The linked application is named after the link, as the user sees it.
    #expect(result.dictionaries.map(\.name) == ["Linked", "Own"])
    #expect(result.dictionaries.map(\.sources) == [[apps.path + "/Linked.app/Real.sdef"], [apps.path + "/Own.app/Own.sdef"]])
    #expect(result.problems.isEmpty)
}

@Test func `built-in terminology has script suite terms`() throws {
    let registry = try Registry.default()
    // TextEdit and Database Events have no SDEF file: their terms come from script suites.
    #expect(registry.dictionary("TextEdit") != nil)
    #expect(registry.dictionary("Database Events") != nil)
    #expect(registry.dictionary("TextEdit")?.sources.contains { $0.hasSuffix("TextEdit.scriptSuite") } == true)
    // System Events names its scripting definition: the script suites it still has are not read.
    let events = try #require(registry.dictionary("System Events"))
    #expect(events.sources.contains { $0.hasSuffix("SystemEvents.sdef") })
    #expect(!events.sources.contains { $0.hasSuffix(".scriptSuite") })
}

// MARK: - Definition files far from what an application has

/**
 A definition can nest elements as deep as it is long. The tree was read
 by a function that calls itself for each level, and 2,000 levels ended
 the program. Elements deeper than `maximumElementDepth` are left out
 now: a term is never that deep.
 */
@Test func `elements nested too deep are left out`() throws {
    func definition(suites: Int) -> Data {
        let open = String(repeating: #"<suite name="s" code="abcd">"#, count: suites)
        let close = String(repeating: "</suite>", count: suites)
        return Data((#"<dictionary><class name="top" code="ctop"/>"# + open + #"<class name="thing" code="thng"><synonym code="thn2"/></class>"# + close + "</dictionary>").utf8)
    }
    // dictionary, the suites, the class, its synonym: the synonym is at level suites + 3.
    let kept = try parseSDEF(name: "Kept", data: definition(suites: maximumElementDepth - 3))
    #expect(kept.terms == ["ctop": "top", "thng": "thing", "thn2": "thing"])
    let synonymLeftOut = try parseSDEF(name: "Edge", data: definition(suites: maximumElementDepth - 2))
    #expect(synonymLeftOut.terms == ["ctop": "top", "thng": "thing"])
    for suites in [maximumElementDepth - 1, 2000, 40000] {
        let deep = try parseSDEF(name: "Deep", data: definition(suites: suites))
        #expect(deep.terms == ["ctop": "top"])
    }
    // What comes after the deep part is read as before.
    let source = "<dictionary>" + String(repeating: "<a>", count: 500) + String(repeating: "</a>", count: 500) + #"<suite><class name="after" code="aftr"/></suite></dictionary>"#
    #expect(try parseSDEF(name: "After", data: Data(source.utf8)).terms == ["aftr": "after"])
}

/**
 A script suite with 40,000 classes, each with an attribute, and as many
 commands and enumerations. The table of words was taken again for each
 entry, and a table from a property list is copied each time: 20,000
 classes took 34 seconds, and the time grew with the square of the
 count. Each table is taken once now.
 */
@Test(.timeLimit(.minutes(1))) func `a long script suite is read in a time that follows its length`() throws {
    let count = 40000
    func code(_ index: Int) -> String {
        String(String(index + 0x10000, radix: 16).suffix(4))
    }
    var classes: [String: Any] = [:]
    var classWords: [String: Any] = [:]
    var commands: [String: Any] = [:]
    var commandWords: [String: Any] = [:]
    var enumerations: [String: Any] = [:]
    var enumerationWords: [String: Any] = [:]
    for index in 0 ..< count {
        let key = "K\(index)"
        classes[key] = ["AppleEventCode": code(index), "Attributes": ["a": ["AppleEventCode": code(index + 1)]]]
        classWords[key] = ["Name": "thing \(index)", "Attributes": ["a": ["Name": "part \(index)"]]]
        commands[key] = ["AppleEventClassCode": "prob", "AppleEventCode": code(index), "Arguments": ["x": ["AppleEventCode": "argx"]]]
        commandWords[key] = ["Name": "do \(index)", "Arguments": ["x": ["Name": "with x"]]]
        enumerations[key] = ["AppleEventCode": "enum", "Enumerators": ["e": code(index)]]
        enumerationWords[key] = ["e": ["Name": "choice \(index)"]]
    }
    let suite = try PropertyListSerialization.data(fromPropertyList: ["Classes": classes, "Commands": commands, "Enumerations": enumerations], format: .binary, options: 0)
    let terminology = try PropertyListSerialization.data(fromPropertyList: ["Classes": classWords, "Commands": commandWords, "Enumerations": enumerationWords], format: .binary, options: 0)
    let dictionary = try parseScriptSuite(name: "Long", suite: suite, terminology: terminology)
    // The codes are four hexadecimal digits: 65,536 of them at most, so all 40,000 are there.
    #expect(dictionary.commands.count == count)
    #expect(dictionary.enums.count == count)
    #expect(dictionary.terms.count == count + 1)
    #expect(try dictionary.commands[EventCode(parsing: "prob0000")]?.parameters["argx"]?.name == "with x")
}

// MARK: - An application that anyone made

/**
 An application can hold a link to any folder of the disk. A scan of the
 application followed it, and read every definition it found there:

 ```
 root/Thing.app/Contents/Resources/out  ──▶  root/Elsewhere       not followed
 root/Thing.app/Contents/Other.sdef     ──▶  a file               read: a file, not a folder
 root/Apps/Linked.app                   ──▶  root/Elsewhere/Real.app    followed, as before
 ```
 */
@Test func `scan does not follow a link inside a bundle`() throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("osatool-bundle-links-\(UUID().uuidString)")
    let resources = root.appendingPathComponent("Thing.app/Contents/Resources")
    let real = root.appendingPathComponent("Elsewhere/Real.app")
    let apps = root.appendingPathComponent("Apps")
    for folder in [resources, real, apps] {
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    defer { try? manager.removeItem(at: root) }
    try Data(definition.utf8).write(to: resources.appendingPathComponent("Thing.sdef"))
    try Data(definition.utf8).write(to: real.appendingPathComponent("Real.sdef"))
    try manager.createSymbolicLink(at: resources.appendingPathComponent("out"), withDestinationURL: root.appendingPathComponent("Elsewhere"))
    try manager.createSymbolicLink(at: resources.appendingPathComponent("Other.sdef"), withDestinationURL: real.appendingPathComponent("Real.sdef"))
    try manager.createSymbolicLink(at: apps.appendingPathComponent("Linked.app"), withDestinationURL: real)

    // The application alone, by its path and from the folder around it.
    let thing = root.appendingPathComponent("Thing.app").path
    for paths in [[thing], [thing + "/Contents"], [thing, apps.path]] {
        let result = scanTerminology(paths: paths)
        #expect(result.dictionaries.map(\.name) == (paths.count == 1 ? ["Thing"] : ["Linked", "Thing"]), "\(paths)")
        #expect(result.dictionaries.last?.sources.map { ($0 as NSString).lastPathComponent } == ["Other.sdef", "Thing.sdef"])
        #expect(result.problems.isEmpty)
    }
    // The whole folder: the real application is found where it is. The link of the
    // plain folder stays inside what is searched, so it is not followed.
    #expect(scanTerminology(paths: [root.path]).dictionaries.map(\.name) == ["Real", "Thing"])
}

/** The innermost bundle around a file gives its dictionary a name, and tells what kind of thing it is. */
@Test func `the innermost bundle around a file is its owner`() {
    #expect("/Applications/Xcode.app/Contents/Applications/Instruments.app/Contents/Resources/I.sdef".owner == "/Applications/Xcode.app/Contents/Applications/Instruments.app")
    #expect("/Applications/Safari.app".owner == nil)
    #expect("/Applications/Safari.app/Contents".owner == "/Applications/Safari.app")
    #expect("/System/Library/ScriptingDefinitions/CocoaStandard.sdef".owner == nil)
    // A path that starts with the bundle.
    #expect("Thing.app/Contents/Resources/Other.sdef".owner == "Thing.app")
    #expect("Thing.app/Contents/Resources/Other.sdef".dictionaryName == "Thing")
    #expect("Thing.app/Contents/Resources/Other.sdef".applicationBundle == "Thing.app")
    #expect("Plug.osax/Contents/Resources/Plug.sdef".applicationBundle == nil)
    #expect("".owner == nil && "/".owner == nil && "Thing.sdef".owner == nil)

    // A scripting addition is a dictionary whose first file is in an `.osax` bundle.
    func dictionary(_ sources: [String]) -> ScriptingDictionary {
        ScriptingDictionary(name: "Thing", sources: sources)
    }
    #expect(dictionary(["/Library/ScriptingAdditions/Plug.osax/Contents/Resources/Plug.sdef"]).isScriptingAddition)
    #expect(dictionary(["/tmp/Thing.app/Contents/Resources/Scripting Additions/Plug.osax/Contents/Resources/Plug.sdef"]).isScriptingAddition)
    // An application inside an `.osax` folder, and one that includes a file of a scripting addition.
    #expect(!dictionary(["/tmp/Box.osax/Thing.app/Contents/Resources/Thing.sdef"]).isScriptingAddition)
    #expect(!dictionary(["/tmp/Thing.app/Contents/Resources/Thing.sdef", "/System/Library/ScriptingAdditions/StandardAdditions.osax/Contents/Resources/StandardAdditions.sdef"]).isScriptingAddition)
    #expect(!dictionary([]).isScriptingAddition)
    #expect(ScriptingDictionary(name: standardAdditionsName).isScriptingAddition)
}
