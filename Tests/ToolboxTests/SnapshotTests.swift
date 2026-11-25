import OSAToolbox
import Testing
import TestSupport

/**
 Checks that the output of the tool did not change.

 The expected files are under `testdata/snapshots`; its README tells how
 to write them again when a change is wanted.
 */

let snapshotInputs: [String] = TestData.compiledFixtures.map { "compiled/\($0)" } + ["demo", "seccon"]

func snapshotName(_ input: String) -> String {
    String(input.split(separator: "/").last!)
}

@Test(arguments: snapshotInputs)
func `disassembly text matches snapshot`(input: String) throws {
    let listing = try disassemble(TestData.bytes("\(input).scpt"))
    #expect(try listing.text() == (TestData.text("snapshots/\(snapshotName(input)).disasm.txt")))
}

@Test(arguments: snapshotInputs)
func `disassembly JSON matches snapshot`(input: String) throws {
    let listing = try disassemble(TestData.bytes("\(input).scpt"))
    #expect(try listing.json() == (TestData.text("snapshots/\(snapshotName(input)).disasm.json")))
}

@Test(arguments: ["demo", "seccon"])
func `sample source matches snapshot`(name: String) throws {
    let data = try TestData.bytes("\(name).scpt")
    #expect(try decompile(data).source == (TestData.text("snapshots/\(name).applescript")))
    let folded = try decompile(data, options: DecompileOptions(passes: [.strings]))
    #expect(try folded.source == (TestData.text("snapshots/\(name).strings.applescript")))
}

@Test func `wrapped sample source matches snapshot`() throws {
    let result = try decompile(TestData.bytes("seccon.scpt"), options: DecompileOptions(disableEmbeddedUnwrap: true))
    #expect(try result.source == (TestData.text("snapshots/seccon.wrapped.applescript")))
}
