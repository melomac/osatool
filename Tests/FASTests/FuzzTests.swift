import FAS
import Testing
import TestSupport

/**
 A small random generator (SplitMix64) with a fixed seed.

 The test below feeds a few seed inputs and a fixed list of damaged copies
 of them. The list is the same on every run, so a failure can be
 reproduced. The coverage-guided fuzzer is separate: see `Scripts/fuzz.sh`.
 */
struct FuzzGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        self.state &+= 0x9e37_79b9_7f4a_7c15
        var mixed = self.state
        mixed = (mixed ^ (mixed >> 30)) &* 0xbf58_476d_1ce4_e5b9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94d0_49bb_1331_11eb
        return mixed ^ (mixed >> 31)
    }

    /** Returns a number from 0 to `bound - 1`. `bound` must be positive. */
    mutating func below(_ bound: Int) -> Int {
        Int(self.next() % UInt64(bound))
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: self.next())
    }

    /**
     Returns a damaged copy of `input`: one to four small changes (a bit
     flip, a new byte, a cut, a removed, added or repeated range).
     */
    mutating func mutate(_ input: [UInt8]) -> [UInt8] {
        let edgeBytes: [UInt8] = [0x00, 0x01, 0x7f, 0x80, 0xff]
        var data = input
        for _ in 0 ..< (1 + self.below(4)) {
            if data.isEmpty {
                data.append(self.byte())
                continue
            }
            let position = self.below(data.count)
            switch self.below(8) {
            case 0:
                data[position] ^= 1 << UInt8(self.below(8))
            case 1:
                data[position] = self.byte()
            case 2:
                data[position] = edgeBytes[self.below(edgeBytes.count)]
            case 3:
                data.removeSubrange(position...)
            case 4:
                let count = min(1 + self.below(8), data.count - position)
                data.removeSubrange(position ..< position + count)
            case 5:
                let added = (0 ..< (1 + self.below(8))).map { _ in self.byte() }
                data.insert(contentsOf: added, at: position)
            case 6:
                let count = min(1 + self.below(32), data.count - position)
                data.insert(contentsOf: Array(data[position ..< position + count]), at: position)
            default:
                // A 16-bit field (a size, a count or a reference) at a limit.
                let edge = edgeBytes[below(edgeBytes.count)]
                data[position] = edge
                if position + 1 < data.count {
                    data[position + 1] = self.below(2) == 0 ? edge : 0xff
                }
            }
        }
        return data
    }
}

/**
 The parser may reject an input, but it must not crash and it must stay
 inside its limits.
 */
@Test func `fuzz parse`() throws {
    let seeds: [[UInt8]] = try [
        Array("FasdUAS 1.101.10".utf8) + [0x03, 0x00, 0x00, 0x00, 0x01],
        TestData.bytes("demo.scpt"),
        TestData.bytes("seccon.scpt"),
    ]
    var limits = Limits.defaults()
    limits.maxInputBytes = 1 << 20
    limits.maxBlobBytes = 1 << 20
    limits.maxObjects = 10000
    limits.maxReferences = 10000
    limits.maxDepth = 128
    let options = ParseOptions(limits: limits)

    var generator = FuzzGenerator(state: 0x4661_7364_5541_5320)
    var inputs = 0
    for seed in seeds {
        _ = try? parse(seed, options: options)
        inputs += 1
        // Every cut of the first bytes: the preamble and the first header.
        for length in 0 ..< min(seed.count, 64) {
            _ = try? parse(Array(seed[..<length]), options: options)
            inputs += 1
        }
        for _ in 0 ..< 400 {
            _ = try? parse(generator.mutate(seed), options: options)
            inputs += 1
        }
    }
    #expect(inputs == 1352)
}
