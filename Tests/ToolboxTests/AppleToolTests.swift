import FAS
import Foundation
import OSAToolbox
import Testing
import TestSupport

/**
 Tests that ask Apple's own tools to judge the decompiled source.

 They run only when the environment variable `OSATOOL_APPLE_TOOLS` is
 set, because `osacompile` can start an application to read its
 dictionary:

 ```sh
 OSATOOL_APPLE_TOOLS=1 swift test --filter "Apple"
 ```

 Two questions are asked for each fixture:

 ```
 fixture.scpt ── osatool ──▶ source ── osacompile -x ──▶ again.scpt
      │                                                      │
      └──────────────── the same data? ─────────────────────┘

 source ── osacompile ──▶ editable.scpt ── osadecompile ──▶ the same text?
 ```

 The first one says that the source means what the script does. The
 second one says that the source is written the way Apple writes it:
 `osadecompile` gives back the text of an editable script, and changes
 only what its own printer would write in another way.

 Apple's tools run in one fixed locale: see `appleToolLocale`.
 */
let appleToolsEnabled = ProcessInfo.processInfo.environment["OSATOOL_APPLE_TOOLS"] != nil

/** The fixtures of `compiled/` and `backrefs/`, as paths under `testdata`. */
private let appleToolFixtures: [String] = {
    let compiled = (try? TestData.names(in: "compiled", suffix: ".scpt")) ?? []
    let backrefs = (try? TestData.names(in: "backrefs", suffix: ".scpt")) ?? []
    return compiled.map { "compiled/\($0)" } + backrefs.map { "backrefs/\($0)" }
}()

/**
 Fixtures that cannot be compiled again on every machine:
 `root_reference_library` uses a script library that must be installed.
 */
private let needsLibrary: Set<String> = ["compiled/root_reference_library"]

/** Fixtures that compile back to other data, for a known reason. There is none now. */
private let compiledAnotherWay: Set<String> = []

/**
 The locale Apple's tools work in during the tests.

 The compiler reads the text of a date, and `osadecompile` writes it,
 with the formats of the user's settings: `2/3/1970` is 3 February on
 one Mac and 2 March on another. With one locale for every run, the
 tests give the same result on every Mac. This one is the plain form of
 the settings of the United States, which is also what the tool writes.
 */
let appleToolLocale = "en_US_POSIX"

/**
 Compiles a source file with `osacompile`, in the locale of the tests.

 The locale variables of the shell (`LANG`, `LC_ALL`) change nothing in
 Apple's tools. A setting given as an argument does:

 ```
 osacompile -o out.scpt source.applescript -AppleLocale en_US_POSIX
 ```

 But `osacompile` reads every argument after its options as one more
 source file. So the folder of the source gets two empty files with
 these two names, and the tool runs in that folder: it takes the two
 words as a setting, and reads the two files as no text.
 */
func osacompile(_ source: URL, to output: URL, runOnly: Bool) throws -> (status: Int32, error: String) {
    let folder = source.deletingLastPathComponent()
    for name in ["-AppleLocale", appleToolLocale] {
        try Data().write(to: folder.appendingPathComponent(name))
    }
    let done = try run(
        "/usr/bin/osacompile", (runOnly ? ["-x"] : []) + ["-o", output.path, source.path, "-AppleLocale", appleToolLocale],
        in: folder,
    )
    return (done.status, done.error)
}

/**
 Prints a compiled script with `osadecompile`, in the locale of the
 tests. This tool takes the setting after the file. It says on standard
 error that it ignores the two words, and uses them.
 */
func osadecompile(_ script: URL) throws -> (status: Int32, output: Data, error: String) {
    try run("/usr/bin/osadecompile", [script.path, "-AppleLocale", appleToolLocale])
}

/** Runs a tool, in a folder when one is given, and returns what it prints. */
func run(_ tool: String, _ arguments: [String], in folder: URL? = nil) throws -> (status: Int32, output: Data, error: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = folder
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let printed = output.fileHandleForReading.readDataToEndOfFile()
    let complaint = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, printed, String(decoding: complaint, as: UTF8.self))
}

/** Writes the decompiled source of a fixture in a new folder, and returns the folder and the file. */
private func decompiledSource(_ fixture: String) throws -> (folder: URL, source: URL, text: String) {
    let text = try decompile(TestData.bytes(fixture + ".scpt")).source
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-apple-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("source.applescript")
    try Data(text.utf8).write(to: source)
    return (folder, source, text)
}

/** The lines of a source that carry text: no empty line, spaces for tabs, nothing after the last word. */
func lines(_ text: String) -> [String] {
    text.replacingOccurrences(of: "\t", with: "    ").split(separator: "\n").map { line in
        var line = String(line)
        while line.hasSuffix(" ") {
            line.removeLast()
        }
        return line
    }.filter { !$0.isEmpty }
}

@Test(.enabled(if: appleToolsEnabled), arguments: appleToolFixtures)
func `the decompiled source compiles to the same code`(fixture: String) throws {
    guard !needsLibrary.contains(fixture) else {
        return
    }
    let original = try TestData.bytes(fixture + ".scpt")
    let (folder, source, _) = try decompiledSource(fixture)
    defer { try? FileManager.default.removeItem(at: folder) }

    let again = folder.appendingPathComponent("again.scpt")
    let compiled = try osacompile(source, to: again, runOnly: true)
    try #require(compiled.status == 0, "osacompile: \(compiled.error)")

    // The whole content of the two files: code, literals, names, properties.
    let want = try FAS.parse(original, options: ParseOptions()).outline(comparable: true).split(separator: "\n")
    let got = try FAS.parse([UInt8](Data(contentsOf: again)), options: ParseOptions()).outline(comparable: true).split(separator: "\n")
    if want != got {
        var index = 0
        while index < want.count, index < got.count, want[index] == got[index] {
            index += 1
        }
        let old = index < want.count ? String(want[index]) : "(end)"
        let new = index < got.count ? String(got[index]) : "(end)"
        withKnownIssue(isIntermittent: false) {
            Issue.record("line \(index + 1) of the outline: \(old) => \(new)")
        } when: {
            compiledAnotherWay.contains(fixture)
        }
    } else {
        #expect(!compiledAnotherWay.contains(fixture), "the fixture is now read back the same: take it out of `compiledAnotherWay`")
    }
}

@Test(.enabled(if: appleToolsEnabled), arguments: appleToolFixtures)
func `Apple prints the decompiled source unchanged`(fixture: String) throws {
    guard !needsLibrary.contains(fixture) else {
        return
    }
    let (folder, source, text) = try decompiledSource(fixture)
    defer { try? FileManager.default.removeItem(at: folder) }

    let editable = folder.appendingPathComponent("editable.scpt")
    let compiled = try osacompile(source, to: editable, runOnly: false)
    try #require(compiled.status == 0, "osacompile: \(compiled.error)")
    let printed = try osadecompile(editable)
    try #require(printed.status == 0, "osadecompile: \(printed.error)")

    #expect(lines(String(decoding: printed.output, as: UTF8.self)) == lines(text))
}
