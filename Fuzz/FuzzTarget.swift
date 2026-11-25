import Foundation
import OSAToolbox

/**
 The entry point libFuzzer calls, once for every input it creates.

 libFuzzer starts from the sample scripts, changes some bytes, runs this
 function, and looks at which branches of the code were reached. An
 input that reaches new code is kept and changed again:

 ```
 corpus ──▶ mutate ──▶ fuzzOneInput ──▶ new coverage? ──yes──▶ add to corpus
    ▲                       │
    └───────────────────────┘        crash, hang or memory growth ──▶ saved to Fuzz/artifacts
 ```

 The whole tool runs on each input:

 1. `disassemble`, then the text and JSON printers;
 2. `decompile` with the `strings` pass, then the source printer. A
    JavaScript for Automation script goes another way there: its source
    is taken out of a property list.

 An input the tool rejects with an error is fine. Only a crash, a run
 that takes too long, or too much memory is a finding.

 The limits are small, so that one input cannot ask for a very large
 allocation through the parser.
 */
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOneInput(_ start: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    let input: [UInt8] = if let start, count > 0 {
        Array(UnsafeBufferPointer(start: start, count: count))
    } else {
        []
    }
    let limits = Limits(maxInputBytes: 1 << 20, maxObjects: 10000, maxReferences: 10000, maxDepth: 128, maxBlobBytes: 1 << 20)

    // Foundation frees its objects when a pool ends, and libFuzzer has none around its loop.
    autoreleasepool {
        if let listing = try? disassemble(input, options: DisassembleOptions(limits: limits)) {
            _ = listing.text()
            _ = listing.json()
        }
        _ = try? decompile(input, options: DecompileOptions(limits: limits, passes: [.strings]))
    }
    return 0
}
