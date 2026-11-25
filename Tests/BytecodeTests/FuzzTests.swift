import Bytecode
import Testing

/**
 A small random generator (SplitMix64) with a fixed seed.

 The test below feeds a few seed inputs and a fixed list of other inputs.
 The list is the same on every run, so a failure can be reproduced. The
 coverage-guided fuzzer is separate: see `Scripts/fuzz.sh`.
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
     flip, a new byte, a cut, a removed or added range).
     */
    mutating func mutate(_ input: [UInt8]) -> [UInt8] {
        var data = input
        for _ in 0 ..< (1 + self.below(4)) {
            if data.isEmpty {
                data.append(self.byte())
                continue
            }
            let position = self.below(data.count)
            switch self.below(5) {
            case 0:
                data[position] ^= 1 << UInt8(self.below(8))
            case 1:
                data[position] = self.byte()
            case 2:
                data.removeSubrange(position...)
            case 3:
                let count = min(1 + self.below(4), data.count - position)
                data.removeSubrange(position ..< position + count)
            default:
                let added = (0 ..< (1 + self.below(4))).map { _ in self.byte() }
                data.insert(contentsOf: added, at: position)
            }
        }
        return data
    }
}

/**
 In permissive mode the decoder must accept any bytes without a crash.
 */
@Test func `fuzz decode`() {
    let seeds: [[UInt8]] = [
        [0xe0, 0x6b, 0x1e, 0x0f],
        [0x62, 0, 1, 0, 2, 0x59, 0xff, 0xf9],
    ]
    var inputs = 0
    func run(_ code: [UInt8]) {
        _ = try? decode(2, code, strict: false)
        inputs += 1
    }

    run([])
    // Every opcode with zero to four bytes after it: complete and cut operands.
    for opcode in UInt8.min ... UInt8.max {
        for tail in 0 ... 4 {
            run([opcode] + [UInt8](repeating: 0xff, count: tail))
        }
    }
    var generator = FuzzGenerator(state: 0x4279_7465_636f_6465)
    for seed in seeds {
        run(seed)
        for _ in 0 ..< 300 {
            run(generator.mutate(seed))
        }
    }
    // Random code, with no relation to the seeds.
    for _ in 0 ..< 300 {
        run((0 ..< generator.below(48)).map { _ in generator.byte() })
    }
    #expect(inputs == 1 + 256 * 5 + 2 * 301 + 300)
}
