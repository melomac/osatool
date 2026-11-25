import FAS
import Foundation
import OSAToolbox
import Testing
import TestSupport

/**
 Small scripts, one for each form of the language, read back by the
 tool and judged by Apple's tools.

 The scripts are in `testdata/probes`. A file holds many of them; a line
 `--- name` starts one. Each script is compiled alone, so one problem
 does not hide another:

 ```
 probe ── osacompile -x ──▶ a.scpt ── osatool ──▶ text
 text ─── osacompile -x ──▶ b.scpt          the same data as a.scpt?
 text ─── osacompile ─────▶ c.scpt ── osadecompile ──▶ the same text?
 probe ── osacompile ─────▶ e.scpt ── osatool ──▶ the same text?
 ```

 "The same data" is the whole content of the two files (see
 `Document.outline`): code, literals, names of parameters and
 variables, properties and script objects.

 Like the other tests that use Apple's tools, these run only when the
 environment variable `OSATOOL_APPLE_TOOLS` is set: `osacompile` reads
 the dictionary of each application a probe tells (the Finder, System
 Events, Mail, Safari, Terminal, TextEdit), and can start it for that.
 No probe is ever run. `OSATOOL_PROBE` keeps the probes whose name
 contains its value.

 The compiled form of each probe and the source the tool prints for it
 are kept too, so that every run of the tests reads the probes back,
 with no tool of Apple:

 ```
 probes/values.txt             the probes
 probes/values.compiled.txt    each one compiled, as base64 text
 probes/values.expected.txt    the source the tool prints for each one
 ```

 `Scripts/update-probes.sh` writes the last two again.
 */
struct Probe: CustomTestStringConvertible, Sendable {
    var name: String
    var source: String

    var testDescription: String {
        self.name
    }
}

/** The names of the probe files, without `.txt`: `values`, `operators`, … */
private let probeGroups: [String] = ((try? TestData.names(in: "probes", suffix: ".txt")) ?? [])
    .filter { !$0.hasSuffix(".compiled") && !$0.hasSuffix(".expected") }

/**
 Reads the sections of a file of `testdata/probes`: a line `--- name`
 starts one, and the lines after it are its text.
 */
private func sections(_ file: String, group: String) -> [Probe] {
    var found: [Probe] = []
    var name: String?
    var lines: [Substring] = []
    func end() {
        if let name {
            found.append(Probe(name: name, source: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"))
        }
    }
    for line in ((try? TestData.text("probes/\(file)")) ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("--- ") {
            end()
            name = group + "." + line.dropFirst(4).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
            lines = []
        } else {
            lines.append(line)
        }
    }
    end()
    return found
}

/** Keeps the probes named by `OSATOOL_PROBE`, or all of them. */
private func chosen(_ probes: [Probe]) -> [Probe] {
    guard let only = ProcessInfo.processInfo.environment["OSATOOL_PROBE"] else {
        return probes
    }
    return probes.filter { $0.name.contains(only) }
}

/** The probes of every file in `testdata/probes`. */
private let probes: [Probe] = chosen(probeGroups.flatMap { sections("\($0).txt", group: $0) })

/** The compiled probes: the `source` of each one is its script, as base64 text. */
private let compiledProbes: [Probe] = chosen(probeGroups.flatMap { sections("\($0).compiled.txt", group: $0) })

/** The source the tool prints for each compiled probe, by the name of the probe. */
private let expectedProbeSources: [String: String] = Dictionary(
    probeGroups.flatMap { sections("\($0).expected.txt", group: $0) }.map { ($0.name, $0.source) },
    uniquingKeysWith: { first, _ in first },
)

/** Every run of the tests reads the compiled probes back: no tool of Apple is needed. */
@Test(arguments: compiledProbes)
func `a compiled probe decompiles to its expected source`(probe: Probe) throws {
    let script = try #require(Data(base64Encoded: probe.source, options: .ignoreUnknownCharacters))
    let result = try decompile([UInt8](script), options: DecompileOptions(strict: true))
    #expect(result.source.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" == expectedProbeSources[probe.name])
}

/** The files with the compiled probes hold every probe: `Scripts/update-probes.sh` was run. */
@Test func `every probe has its compiled form`() {
    guard ProcessInfo.processInfo.environment["OSATOOL_PROBE"] == nil else {
        return
    }
    #expect(!probes.isEmpty)
    #expect(compiledProbes.map(\.name) == probes.map(\.name))
    #expect(Set(expectedProbeSources.keys) == Set(probes.map(\.name)))
}

/**
 Writes `<group>.compiled.txt` and `<group>.expected.txt` again, with
 `osacompile`. It runs only when `OSATOOL_WRITE_PROBES` is set, with
 `OSATOOL_APPLE_TOOLS` like every test that calls a tool of Apple:
 compiling a probe that tells Mail, Safari, Terminal or TextEdit can start that
 application. See `Scripts/update-probes.sh`.
 */
@Test(.enabled(if: appleToolsEnabled && ProcessInfo.processInfo.environment["OSATOOL_WRITE_PROBES"] != nil))
func `write the compiled probes`() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-probes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for group in probeGroups {
        var compiled = ""
        var expected = ""
        for probe in sections("\(group).txt", group: group) {
            let title = "--- " + probe.name.dropFirst(group.count + 1).replacingOccurrences(of: "_", with: " ") + "\n"
            let source = folder.appendingPathComponent("probe.applescript")
            let output = folder.appendingPathComponent("probe.scpt")
            try Data(probe.source.utf8).write(to: source)
            let done = try osacompile(source, to: output, runOnly: true)
            try #require(done.status == 0, "\(probe.name): \(done.error)")
            let script = try Data(contentsOf: output)
            compiled += title + script.base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed]) + "\n"
            try expected += title + (decompile([UInt8](script), options: DecompileOptions(strict: true)).source)
        }
        try Data(compiled.utf8).write(to: TestData.url("probes/\(group).compiled.txt"))
        try Data(expected.utf8).write(to: TestData.url("probes/\(group).expected.txt"))
    }
}

/**
 The probes that are not read back the same, each with the reason.
 A probe listed here must still fail: when it passes, the test says so.
 */
private let knownProbeDifferences: [String: String] = [
    "commands.name_that_is_the_first_word_of_a_keyword": "Apple prints `start with` for |start| with, which does not compile; the tool keeps the bars",
    "commands.name_that_is_the_first_word_of_a_preposition": "Apple prints `apart from`, `out of`, `info for` for a name between bars and the next word, which does not compile or is other code; the tool keeps the bars",
    "commands.name_that_joins_the_next_word_in_a_handler_header": "Apple prints `contained by`, `comes after`, `out of` for a name between bars and the next word, which does not compile; the tool keeps the bars",
    "commands.property_of_the_target_given_by_its_code": "Apple prints «class sdsk» for «property sdsk» with no container, and the compiler reads that as the class; the tool prints the property",
    "handlers.direct_only": "the order of labeled arguments is not kept; Apple's printer moves them too",
    "scopes.the_property_with_the_code_of_a_class_that_is_its_own_plural": "Apple prints `text of x` for «property ctxt» of x, and the compiler reads that as `every text of x`; the tool prints the code",
    "scopes.properties_inside_and_outside_a_tell_block": "outside a `tell` block Apple prints `properties` for «class pALL», and the compiler reads that word as `every property`; the tool prints the code",
    "scopes.use_two_applications": "with `use application id`, the compiler adds `of application id \"…\"` and shares its text with the `use` line; the tool prints it, so the text is stored once more",
    "handlers.properties": "Apple shows twelve digits of pi; the tool prints all the digits of the stored number",
    "text.empty_and_whitespace_strings": "Apple prints a tab and a line end inside a string as they are",
    "text.linefeeds_in_literals": "Apple prints a tab and a line end inside a string as they are",
    "values.strings": "Apple prints a tab and a line end inside a string as they are; the tool writes \\t and \\n",
]

/** What one probe shows: nothing, or the first difference found. */
private func difference(_ probe: Probe) throws -> String? {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }
    func compile(_ source: URL, to output: URL, runOnly: Bool) throws -> String? {
        let done = try osacompile(source, to: output, runOnly: runOnly)
        return done.status == 0 ? nil : String(done.error.trimmingCharacters(in: .whitespacesAndNewlines).suffix(150))
    }
    func bytes(_ url: URL) throws -> [UInt8] {
        try [UInt8](Data(contentsOf: url))
    }

    try Data(probe.source.utf8).write(to: file("probe.applescript"))
    if let error = try compile(file("probe.applescript"), to: file("a.scpt"), runOnly: true) {
        return "PROBE the probe does not compile: \(error)"
    }
    let original = try bytes(file("a.scpt"))
    let result: DecompileResult
    do {
        result = try decompile(original, options: DecompileOptions(strict: true))
    } catch {
        return "STRICT \(error)"
    }
    let text = result.source
    try Data(text.utf8).write(to: file("text.applescript"))
    if let error = try compile(file("text.applescript"), to: file("b.scpt"), runOnly: true) {
        return "COMPILE the text does not compile: \(error)\n\(text)"
    }
    let want = try FAS.parse(original, options: ParseOptions()).outline(comparable: true).split(separator: "\n")
    let got = try FAS.parse(bytes(file("b.scpt")), options: ParseOptions()).outline(comparable: true).split(separator: "\n")
    if want != got {
        var index = 0
        while index < want.count, index < got.count, want[index] == got[index] {
            index += 1
        }
        let before = want[max(0, index - 2) ..< index].joined(separator: " / ")
        let old = index < want.count ? String(want[index]) : "(end)"
        let new = index < got.count ? String(got[index]) : "(end)"
        return "DATA line \(index + 1): \(old) => \(new)  after: \(before)\n\(text)"
    }
    if let error = try compile(file("text.applescript"), to: file("c.scpt"), runOnly: false) {
        return "COMPILE the text does not compile as an editable script: \(error)"
    }
    let printed = try osadecompile(file("c.scpt"))
    let ours = lines(text)
    let apple = lines(String(decoding: printed.output, as: UTF8.self))
    if ours != apple {
        let changed = zip(ours, apple).filter { $0 != $1 }.map { "\($0.trimmingCharacters(in: .whitespaces))  =>  \($1.trimmingCharacters(in: .whitespaces))" }
        return "ECHO " + (changed.isEmpty ? "\(ours.count) lines => \(apple.count) lines" : changed.joined(separator: " | "))
    }
    if let error = try compile(file("probe.applescript"), to: file("e.scpt"), runOnly: false) {
        return "PROBE the probe does not compile as an editable script: \(error)"
    }
    let editable = try decompile(bytes(file("e.scpt")), options: DecompileOptions(strict: true)).source
    if editable != text {
        return "EDITABLE the script saved editable is printed another way"
    }
    return nil
}

@Test(.enabled(if: appleToolsEnabled), arguments: probes)
func `a probe is read back the same`(probe: Probe) throws {
    let found = try difference(probe)
    if let reason = knownProbeDifferences[probe.name] {
        withKnownIssue("\(reason)") {
            if let found {
                Issue.record("\(found)")
            }
        }
    } else if let found {
        Issue.record("\(found)")
    }
}

/**
 Writes the outline of the file named by `OSATOOL_OUTLINE` beside it,
 as `<file>.outline.txt`: a help to study how a script is stored.
 */
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSATOOL_OUTLINE"] != nil))
func `outline of a file`() throws {
    let path = try #require(ProcessInfo.processInfo.environment["OSATOOL_OUTLINE"])
    let document = try FAS.parse([UInt8](Data(contentsOf: URL(fileURLWithPath: path))), options: ParseOptions())
    try Data(document.outline().utf8).write(to: URL(fileURLWithPath: path + ".outline.txt"))
}
