import Foundation
import OSAToolbox
import Testing
import TestSupport

/**
 The library as another program uses it: this file imports only
 `OSAToolbox` (and the helper that finds the test files), and uses only
 what is `public`.
 */
@Test func `a program decompiles a script with the library alone`() throws {
    let script = try Data(contentsOf: TestData.url("demo.scpt"))
    let result = try decompile(script)
    #expect(result.source.contains("on run"))
    #expect(!result.embedded)
    #expect(result.diagnostics.isEmpty)

    let listing = try disassemble(script)
    #expect(listing.text().hasPrefix("FAS "))
    #expect(listing.json().contains("\"schema_version\": \(disassemblySchemaVersion)"))
    #expect(listing.functions.first?.instructions.isEmpty == false)
}

/**
 The source comes in two forms: `source`, a `String`, and `sourceData`,
 the same text as `Data` in UTF-8. A program takes the one it needs: the
 text to show it, the data to write it or to hash it.
 */
@Test func `the source is given as text and as data`() throws {
    // This script has text outside ASCII: one character is several bytes.
    let result = try decompile(Data(contentsOf: TestData.url("compiled/unicode_string.scpt")))
    #expect(result.sourceData == Data(result.source.utf8))
    #expect(String(data: result.sourceData, encoding: .utf8) == result.source)
    #expect(result.sourceData.count > result.source.count)

    // In strict mode the error has both forms too. This script decompiles with one diagnostic.
    do {
        _ = try decompile(Data(contentsOf: TestData.url("renamed-handler.scpt")), options: DecompileOptions(strict: true))
        Issue.record("a script with a diagnostic was read in strict mode")
    } catch let error as StrictDecompilationError {
        #expect(!error.source.isEmpty && error.sourceData == Data(error.source.utf8))
    }
}

@Test func `the options of the library`() throws {
    let script = try Data(contentsOf: TestData.url("compiled/ascii_recovery.scpt"))
    let plain = try decompile(script)
    let folded = try decompile(script, options: DecompileOptions(strict: true, passes: [.strings]))
    #expect(try folded.source == (TestData.text("compiled/ascii_recovery.expected.applescript")))
    #expect(plain.source != folded.source)

    // A value of zero means the default bound.
    #expect(Limits().maxDepth == 0)
    #expect(Limits.defaults().maxDepth == 1024)
    #expect(Limits.defaults().maxInputBytes == 64 << 20)
}

/**
 An error of the library says what is wrong in one line, also for a
 program that only has `any Error` and asks for `localizedDescription`.
 */
@Test func `errors of the library have a readable text`() throws {
    let script = try Data(contentsOf: TestData.url("demo.scpt"))
    var options = DecompileOptions()
    options.limits.maxInputBytes = 4
    do {
        _ = try decompile(script, options: options)
        Issue.record("a file over the limit was read")
    } catch {
        #expect(error.localizedDescription.contains("4"), "\(error.localizedDescription)")
        #expect(!error.localizedDescription.contains("couldn’t be completed"), "\(error.localizedDescription)")
    }
    do {
        _ = try decompile(Data("not a script".utf8))
        Issue.record("text was read as a script")
    } catch {
        #expect(!error.localizedDescription.contains("couldn’t be completed"), "\(error.localizedDescription)")
    }

    let strict = StrictDecompilationError(source: "", diagnostics: [Diagnostic(stage: .decode, offset: 16, message: "cut")])
    #expect(strict.localizedDescription == "strict decompilation produced 1 diagnostics")
    #expect(strict.diagnostics.first?.description == "decode at 0x10: cut")
    #expect(Diagnostic(stage: .parse, message: "odd").description == "parse: odd")
}

/** The terminology: what is in the program, a saved file, and the definition of an application. */
@Test func `terminology of the library`() throws {
    var terminology = try ScriptingTerminology.builtIn()
    #expect(terminology.dictionaryNames.contains("Finder"))
    #expect(!terminology.dictionaryNames.contains("One"))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("osatool-library-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let definition = root.appendingPathComponent("One.sdef")
    try Data(#"<dictionary><suite name="One" code="oneS"><class name="one" code="one1"/></suite></dictionary>"#.utf8).write(to: definition)

    let problems = terminology.learn(from: [definition.path, root.appendingPathComponent("Missing.sdef").path])
    #expect(terminology.dictionaryNames.contains("One"))
    #expect(problems.count == 1)
    #expect(problems.first?.contains("Missing.sdef") == true)

    let saved = root.appendingPathComponent("saved.json")
    try Data(#"{ "schema_version": 1, "dictionaries": [{ "name": "Two", "terms": [{ "code": "two2", "name": "two" }] }] }"#.utf8).write(to: saved)
    try terminology.add(contentsOf: saved)
    #expect(terminology.dictionaryNames.contains("Two"))
    #expect(throws: (any Error).self) { try terminology.add(contentsOf: root.appendingPathComponent("nothing.json")) }
    #expect(throws: (any Error).self) { try terminology.add(Data("{".utf8)) }

    // The terminology goes to `decompile` with the options.
    let script = try Data(contentsOf: TestData.url("demo.scpt"))
    let result = try decompile(script, options: DecompileOptions(terminology: terminology))
    #expect(try result.source == decompile(script).source)
}
