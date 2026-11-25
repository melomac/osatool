import FAS
import OSAToolbox
import Testing
import TestSupport

/**
 Inputs that once made the tool crash, found by the fuzzer
 (`Scripts/fuzz.sh`) and kept under `testdata/fuzz`.

 Each file is run the way the fuzzer runs it. The test passes when the
 tool returns, with a result or with an error.
 */
@Test(arguments: (try? TestData.names(in: "fuzz", suffix: ".scpt")) ?? [])
func `fuzz finding does not crash`(name: String) throws {
    let input = try TestData.bytes("fuzz/\(name).scpt")
    let limits = OSAToolbox.Limits(maxInputBytes: 1 << 20, maxObjects: 10000, maxReferences: 10000, maxDepth: 128, maxBlobBytes: 1 << 20)
    if let listing = try? disassemble(input, options: DisassembleOptions(limits: limits)) {
        _ = listing.text()
        _ = listing.json()
    }
    _ = try? decompile(input, options: DecompileOptions(limits: limits, passes: [.strings]))
}

/** A record whose value contains the record itself: the loop is cut and shown. */
@Test func `cyclic literal is cut`() throws {
    let result = try decompile(TestData.bytes("fuzz/cyclic-literal.scpt"))
    #expect(result.source == "property ICON : {type:«cyclic reference»}\n")
}

/**
 Damaged bytecode that uses one expression twice in a larger one, again
 and again. Printed in full, the first file gave 210 MB of source and
 the second one 80 MB. The repeated part is now replaced, and a
 diagnostic says so.
 */
@Test(arguments: ["repeated-expression", "repeated-expression-2"])
func `an expression that repeats itself is cut`(name: String) throws {
    let result = try decompile(TestData.bytes("fuzz/\(name).scpt"))
    #expect(result.source.utf8.count < 1_000_000, "the source has \(result.source.utf8.count) bytes")
    #expect(result.source.contains("«expression too large»"))
    #expect(result.diagnostics.contains { $0.message.contains("repeats one expression too many times") })

    // In strict mode a diagnostic is an error, so the file is refused.
    #expect(throws: (any Error).self) {
        try decompile(TestData.bytes("fuzz/\(name).scpt"), options: DecompileOptions(strict: true))
    }
}
