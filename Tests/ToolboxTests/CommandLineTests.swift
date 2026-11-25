import ArgumentParser
import Foundation
@testable import osatool
import OSAToolbox
import Testing
import TestSupport

/**
 Runs the tool with streams kept in memory.

 It does what ArgumentParser does in the real tool: parse the command
 line, run the subcommand, and turn a thrown error into a message and an
 exit status.
 */
func runTool(_ args: [String], input: [UInt8] = [], learned: URL? = nil) -> (code: Int32, output: String, error: String) {
    var written = ""
    var complaints = ""
    let streams = Streams(readInput: { input }, writeOutput: { written += $0 }, writeError: { complaints += $0 }, learnedTerminology: learned)
    do {
        var command = try OSATool.parseAsRoot(args)
        if let command = command as? any StreamCommand {
            return (command.run(streams), written, complaints)
        }
        try command.run()
        return (0, written, complaints)
    } catch {
        let status = OSATool.exitCode(for: error)
        let message = OSATool.fullMessage(for: error)
        if !message.isEmpty {
            (status == .success ? streams.writeOutput : streams.writeError)(message + "\n")
        }
        return (status.rawValue, written, complaints)
    }
}

@Test func `no arguments prints help`() {
    let result = runTool([])
    #expect(result.code == 0)
    #expect(result.output.contains("USAGE: osatool <subcommand>"))
    #expect(result.output.contains("decompile"))
    #expect(result.output.contains("disassemble"))
}

@Test func `disassemble JSON from stdin`() throws {
    let result = try runTool(["disassemble", "--json", "-"], input: TestData.bytes("demo.scpt"))
    #expect(result.code == 0, "\(result.error)")
    for want in ["\"schema_version\": 1", "\"mnemonic\": \"MessageSend\"", "\"raw_hex\""] {
        #expect(result.output.contains(want), "JSON missing \(want)")
    }
}

@Test func `decompile from stdin`() throws {
    let result = try runTool(["decompile", "-"], input: TestData.bytes("demo.scpt"))
    #expect(result.code == 0, "\(result.error)")
    #expect(result.output.contains("on run"), "source missing run handler")
}

// MARK: - Command line

@Test func `help goes to standard output`() {
    for args in [["--help"], ["help"], ["disassemble", "--help"], ["help", "decompile"]] {
        let result = runTool(args)
        #expect(result.code == 0, "\(args)")
        #expect(result.error.isEmpty, "\(args)")
        #expect(result.output.contains("USAGE: osatool"), "\(args)")
    }
    let help = runTool(["decompile", "--help"])
    for want in ["--strict", "--no-unwrap", "--pass <pass>", "<file>", "(.scpt, .scptd or .app)"] {
        #expect(help.output.contains(want), "help missing \(want)")
    }
}

@Test func `option spellings`() throws {
    let data = try TestData.bytes("compiled/ascii_recovery.scpt")
    let expected = try TestData.text("compiled/ascii_recovery.expected.applescript")
    for args in [["--pass", "strings"], ["--pass=strings"], ["--pass", "strings", "--strict"], ["--strict", "--pass=strings", "--no-unwrap"]] {
        let result = runTool(["decompile"] + args + ["-"], input: data)
        #expect(result.code == 0, "\(args): \(result.error)")
        #expect(result.output == expected, "\(args)")
    }
}

/** A wrong command line ends with status 64 and explains itself on standard error. */
@Test func `command line errors`() {
    let cases: [([String], String)] = [
        (["compile"], "Unexpected argument 'compile'"),
        (["decompile", "--nope", "x.scpt"], "Unknown option '--nope'"),
        (["decompile", "--pass"], "Missing value for '--pass <pass>'"),
        (["decompile", "--pass", "nope", "-"], "unknown pass \"nope\""),
        (["decompile"], "Missing expected argument '<file>'"),
        (["decompile", "a.scpt", "b.scpt"], "Unexpected argument 'b.scpt'"),
    ]
    for (args, want) in cases {
        let result = runTool(args)
        #expect(result.code == 64, "\(args)")
        #expect(result.output.isEmpty, "\(args)")
        #expect(result.error.contains(want), "\(args): \(result.error)")
    }
}

@Test func `missing file and bad input`() {
    let missing = runTool(["decompile", "/nonexistent/osatool-test.scpt"])
    #expect(missing.code == 1)
    #expect(missing.error == "open /nonexistent/osatool-test.scpt: no such file or directory\n")

    let notAScript = runTool(["disassemble", "-"], input: Array("hello world!".utf8))
    #expect(notAScript.code == 1)
    #expect(notAScript.error == "invalid FAS magic \"hell\"\n")
}

/** In strict mode a diagnostic is an error: status 1 and no listing. */
@Test func `strict disassembly fails on diagnostics`() throws {
    let damaged = try TestData.bytes("fuzz/cyclic-literal.scpt")
    let relaxed = runTool(["disassemble", "-"], input: damaged)
    #expect(relaxed.code == 0)
    #expect(relaxed.error.contains("RefID mismatch"))
    let strict = runTool(["disassemble", "--strict", "-"], input: damaged)
    #expect(strict.code == 1)
    #expect(strict.output.isEmpty)
}

// MARK: - JavaScript for Automation

/**
 A JXA script holds its source text. `decompile` prints it as it is: the
 source of `unicode.scpt` has no newline at its end, and none is added.
 `disassemble` says why there is no listing.
 */
@Test func `decompile prints the source of a JXA script`() throws {
    for (script, source) in [("hello", "hello"), ("hello-run-only", "hello"), ("unicode", "unicode")] {
        let result = try runTool(["decompile", "-"], input: TestData.bytes("jxa/\(script).scpt"))
        #expect(result.code == 0, "\(script): \(result.error)")
        #expect(result.error.isEmpty, "\(script)")
        #expect(try result.output == TestData.text("jxa/\(source).js"), "\(script)")
    }
    // The options are for AppleScript: they change nothing.
    let strict = try runTool(["decompile", "--strict", "--pass", "strings", "--no-unwrap", "-"], input: TestData.bytes("jxa/hello.scpt"))
    #expect(try strict.output == TestData.text("jxa/hello.js"))

    for arguments in [["disassemble", "-"], ["disassemble", "--json", "-"]] {
        let listing = try runTool(arguments, input: TestData.bytes("jxa/hello.scpt"))
        #expect(listing.code == 1)
        #expect(listing.output.isEmpty)
        #expect(listing.error == "a JavaScript for Automation (JXA) script holds source text, not bytecode: use 'decompile' to print it\n")
    }
}

/** A JXA script that is cut short, damaged or without source text: one line on standard error, and status 1. */
@Test func `a damaged JXA script is an error`() throws {
    let script = try TestData.bytes("jxa/hello.scpt")
    var damaged = script
    // The last byte of the property list says where its table of offsets is.
    damaged[0x72] = 0xf0
    let cases: [([UInt8], String)] = try [
        (Array(script.prefix(20)), "read JXA trailer at 0x14: unexpected end of data"),
        (Array(script.prefix(100)), "invalid JXA trailer magic \"\\x00\\x00\\x03\\x00\" at 0x60"),
        (Array(script.prefix(0x52) + script.suffix(12)), "read JXA property list at 0x10: damaged property list"),
        (damaged, "read JXA property list at 0x10: damaged property list"),
        (TestData.javaScript(propertyList: TestData.propertyList(["source": "1"])), "JXA property list has no \"script\" key"),
        (TestData.javaScript(propertyList: TestData.propertyList(["script": 1])), "JXA \"script\" value is not text"),
    ]
    for (input, want) in cases {
        let result = runTool(["decompile", "-"], input: input)
        #expect(result.code == 1, "\(want)")
        #expect(result.output.isEmpty, "\(want)")
        #expect(result.error == want + "\n")
    }
}

// MARK: - Bundles

/**
 A script bundle and an applet are folders. The script is one file
 inside, and the tool reads it when it is given the folder:

 ```
 Demo.scptd/Contents/Resources/Scripts/main.scpt
 Demo.app/Contents/Resources/Scripts/main.scpt
 ```
 */
@Test func `a bundle is read through its main script`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-bundle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for (bundle, fixture) in [("Demo.scptd", "demo.scpt"), ("Demo.app", "demo.scpt"), ("JavaScript.scptd", "jxa/hello.scpt"), ("JavaScript.app", "jxa/hello.scpt")] {
        let scripts = root.appendingPathComponent(bundle).appendingPathComponent("Contents/Resources/Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: TestData.url(fixture), to: scripts.appendingPathComponent("main.scpt"))
    }
    func path(_ bundle: String) -> String {
        root.appendingPathComponent(bundle).path
    }

    let source = runTool(["decompile", TestData.url("demo.scpt").path])
    let listing = runTool(["disassemble", TestData.url("demo.scpt").path])
    #expect(source.code == 0)
    #expect(listing.code == 0)
    // A folder is named with or without a last slash.
    for bundle in ["Demo.scptd", "Demo.app", "Demo.scptd/", "Demo.app/"] {
        let decompiled = runTool(["decompile", path(bundle)])
        #expect(decompiled.code == 0, "\(bundle): \(decompiled.error)")
        #expect(decompiled.output == source.output, "\(bundle)")
        let disassembled = runTool(["disassemble", path(bundle)])
        #expect(disassembled.code == 0, "\(bundle): \(disassembled.error)")
        #expect(disassembled.output == listing.output, "\(bundle)")
    }
    for bundle in ["JavaScript.scptd", "JavaScript.app"] {
        let decompiled = runTool(["decompile", path(bundle)])
        #expect(decompiled.code == 0, "\(bundle): \(decompiled.error)")
        #expect(try decompiled.output == TestData.text("jxa/hello.js"), "\(bundle)")
        #expect(runTool(["disassemble", path(bundle)]).error.contains("holds source text, not bytecode"), "\(bundle)")
    }
}

/** A folder that is not a bundle, or a bundle with no script: the error names the file that was looked for. */
@Test func `a bundle with no main script is an error`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-bundle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appendingPathComponent("Empty.scptd")
    let other = root.appendingPathComponent("Other.app")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other.appendingPathComponent("Contents/Resources/Scripts"), withIntermediateDirectories: true)
    try Data().write(to: other.appendingPathComponent("Contents/Resources/Scripts/other.scpt"))
    for bundle in [empty, other] {
        for command in ["decompile", "disassemble"] {
            let result = runTool([command, bundle.path])
            #expect(result.code == 1, "\(command) \(bundle.lastPathComponent)")
            #expect(result.output.isEmpty)
            #expect(result.error == "open \(bundle.path)/Contents/Resources/Scripts/main.scpt: no such file or directory\n")
        }
    }
}

// MARK: - Version, copyright and completion

@Test func `the version is printed`() {
    let result = runTool(["--version"])
    #expect(result.code == 0)
    #expect(result.output == "1.0.0\n")
    #expect(result.error.isEmpty)
}

/**
 The copyright line names one year in the year the tool was first
 published, then a range. A clock set before that year changes nothing.
 */
@Test func `the copyright names the years`() {
    #expect(OSATool.copyrightYears(in: 2026) == "2026")
    #expect(OSATool.copyrightYears(in: 2027) == "2026-2027")
    #expect(OSATool.copyrightYears(in: 2025) == "2026")
}

/** The help of the tool and of every command shows the copyright and the license. */
@Test func `every help shows the copyright`() {
    let year = Calendar(identifier: .gregorian).component(.year, from: .now)
    for args in [["--help"], ["decompile", "--help"], ["disassemble", "--help"], ["learn", "--help"]] {
        let help = runTool(args).output
        #expect(help.contains("Copyright (c) Melomac \(OSATool.copyrightYears(in: year))\n"), "\(args)")
        #expect(help.contains("License GPLv3: GNU General Public License version 3\n"), "\(args)")
        #expect(help.contains("<https://codeberg.org/melomac/osatool/src/LICENSE>\n"), "\(args)")
        // The help is cut into lines of 80 columns: only the start of this one is sure.
        #expect(help.contains("The binary includes third-party code, see NOTICE"), "\(args)")
        #expect(help.contains("<https://codeberg.org/melomac/osatool/src/NOTICE>\n"), "\(args)")
    }
    // The help of `learn` keeps its own text before the copyright.
    #expect(runTool(["learn", "--help"]).output.contains("Folders are searched to any depth"))
}

/**
 The completion scripts offer file names where a command takes a file.

 An argument that declares no completion gets none, and the scripts turn
 off the file names that the shell offers by itself. So `decompile` then
 completed nothing where the file goes. Each argument that is a file
 now says so.

 The script for bash is run in bash, the shell that every Mac has. It is
 asked what it offers for the last word of a command line, like the
 shell asks it when the Tab key is pressed:

 ```
 COMP_WORDS    osatool decompile de
 COMP_CWORD    2                        the word to complete
 COMPREPLY     demo.scpt                what the script offers
 ```
 */
@Test func `the completion script offers file names`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-complete-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Apps"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("demo.scpt"))
    try Data().write(to: root.appendingPathComponent("my script.scpt"))
    let script = root.appendingPathComponent("osatool.bash")
    try Data(OSATool.completionScript(for: .bash).utf8).write(to: script)
    let probe = """
    source "$1"; shift
    COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 ))
    _osatool osatool "${COMP_WORDS[COMP_CWORD]}" "${COMP_WORDS[COMP_CWORD - 1]}"
    printf '%s\\n' "${COMPREPLY[@]}"
    """

    /// What bash offers for the last word of a command line, in the folder `root`.
    func offers(_ words: String...) throws -> [String] {
        let result = try run("/bin/bash", ["--noprofile", "--norc", "-c", probe, "bash", script.path, "osatool"] + words, in: root)
        #expect(result.status == 0, "\(words): \(result.error)")
        return String(decoding: result.output, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
    }

    let files = ["Apps", "demo.scpt", "my script.scpt", "osatool.bash"]
    #expect(try offers("decompile", "") == files)
    #expect(try offers("decompile", "de") == ["demo.scpt"])
    #expect(try offers("decompile", "--strict", "my") == ["my script.scpt"])
    #expect(try offers("disassemble", "--json", "") == files)
    #expect(try offers("learn", "Ap") == ["Apps"])
    #expect(try offers("learn", "Apps", "de") == ["demo.scpt"])
    #expect(try offers("learn", "--output", "de") == ["demo.scpt"])
    #expect(try offers("learn", "-o", "") == files)
    // The names of the passes, and no file name in their place.
    #expect(try offers("decompile", "--pass", "") == DecompilePass.allCases.map(\.rawValue).sorted())
    // The file of `decompile` is given: no second one is offered.
    #expect(try offers("decompile", "demo.scpt", "de").isEmpty)
}

// MARK: - Learning terminology

/**
 `raw_unknown_terms.scpt` uses a class and an event the tool does not
 know. After `learn` reads a definition that names them, `decompile`
 prints the names.

 The script has no `tell` block, so the definition is one of a
 scripting addition: its words are known everywhere. The words of an
 application are known only inside a `tell` block for it.
 */
@Test func `learn then decompile uses the learned terms`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-learn-\(UUID().uuidString)")
    let resources = root.appendingPathComponent("Apps/Probe.osax/Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <dictionary>
        <suite name="Probe" code="ABCD">
            <command name="frobnicate" code="ABCDwxyz"/>
            <class name="widget" code="zzzz"/>
        </suite>
    </dictionary>
    """.utf8).write(to: resources.appendingPathComponent("Probe.sdef"))
    let saved = root.appendingPathComponent("Library/terminology.json")
    let script = try TestData.bytes("compiled/raw_unknown_terms.scpt")

    let before = runTool(["decompile", "-"], input: script, learned: saved)
    #expect(before.output.contains("«class zzzz»"))
    #expect(before.output.contains("«event ABCDwxyz»"))

    let learn = runTool(["learn", root.appendingPathComponent("Apps").path], learned: saved)
    #expect(learn.code == 0, "\(learn.error)")
    #expect(learn.output.contains("Probe: 1 commands, 1 terms, 0 enumerators\n"))
    #expect(learn.output.contains("1 dictionaries saved in \(saved.path)\n"))

    let after = runTool(["decompile", "-"], input: script, learned: saved)
    #expect(after.code == 0)
    #expect(after.output.contains("return widget\n"))
    #expect(after.output.contains("frobnicate"))
    #expect(!after.output.contains("«"))

    // The built-in terminology alone gives the first output again.
    let builtin = runTool(["decompile", "--builtin-terminology", "-"], input: script, learned: saved)
    #expect(builtin.output == before.output)
}

@Test func `learn with output leaves the saved terminology alone`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-learn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let definition = root.appendingPathComponent("One.sdef")
    try Data(#"<dictionary><suite name="One" code="oneS"><class name="one" code="one1"/></suite></dictionary>"#.utf8).write(to: definition)
    let saved = root.appendingPathComponent("saved.json")
    let output = root.appendingPathComponent("out.json")

    let result = runTool(["learn", "--output", output.path, definition.path], learned: saved)
    #expect(result.code == 0, "\(result.error)")
    #expect(FileManager.default.fileExists(atPath: output.path))
    #expect(!FileManager.default.fileExists(atPath: saved.path))
    #expect(try String(contentsOf: output, encoding: .utf8).contains(#"{ "code": "one1", "name": "one" }"#))
}

/**
 `--compact` writes the JSON on one line, `--compress` makes a zlib
 stream of the file. A file written by `learn` can be given to `learn`
 again, and `decompile` reads every form.
 */
@Test func `learn writes compact and compressed files`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-learn-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let definition = root.appendingPathComponent("One.sdef")
    try Data(#"<dictionary><suite name="One" code="oneS"><class name="one" code="one1"/></suite></dictionary>"#.utf8).write(to: definition)
    let readable = root.appendingPathComponent("readable.json")
    let compact = root.appendingPathComponent("compact.json")
    let small = root.appendingPathComponent("small.sref")

    #expect(runTool(["learn", "--output", readable.path, definition.path]).code == 0)
    let first = runTool(["learn", "--compact", "--output", compact.path, readable.path])
    #expect(first.code == 0, "\(first.error)")
    let text = try String(contentsOf: compact, encoding: .utf8)
    #expect(text.contains(#"{"code":"one1","name":"one"}"#))
    #expect(text.split(separator: "\n").count == 1)

    let second = runTool(["learn", "--compact", "--compress", "--output", small.path, compact.path])
    #expect(second.code == 0, "\(second.error)")
    #expect(second.output.contains("One: 0 commands, 1 terms, 0 enumerators\n"))
    let stream = try Data(contentsOf: small)
    #expect(stream.prefix(2) == Data([0x78, 0x9c]))

    // The compressed file as the saved terminology of the user: `learn` adds to it.
    let other = root.appendingPathComponent("Two.sdef")
    try Data(#"<dictionary><suite name="Two" code="twoS"><class name="two" code="two2"/></suite></dictionary>"#.utf8).write(to: other)
    let third = runTool(["learn", other.path], learned: small)
    #expect(third.code == 0, "\(third.error)")
    #expect(third.output.contains("2 dictionaries saved in \(small.path)\n"))
}

@Test func `learn fails when nothing is found`() {
    let result = runTool(["learn", "/nonexistent/osatool-test"], learned: nil)
    #expect(result.code == 1)
    #expect(result.error.contains("/nonexistent/osatool-test: no such file or directory\n"))
    #expect(result.error.contains("no scripting definition found\n"))
}

/** A damaged saved file is reported; the built-in terminology is still used. */
@Test func `a damaged saved file does not stop decompile`() throws {
    let saved = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-bad-\(UUID().uuidString).json")
    try Data("not json".utf8).write(to: saved)
    defer { try? FileManager.default.removeItem(at: saved) }
    let result = try runTool(["decompile", "-"], input: TestData.bytes("compiled/sdef_terms.scpt"), learned: saved)
    #expect(result.code == 0)
    #expect(result.error.contains("learned terminology is not used"))
    #expect(result.output.contains("quoted form of inputText"))
}
