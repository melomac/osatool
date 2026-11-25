import Bytecode
import Extensions
import Testing

@Test func `opcode table and operands`() throws {
    let names = Opcode.names
    try #require(names.count == 256, "unexpected opcode table")
    #expect(names[12] == "MessageSend")
    #expect(names[89] == "Jump")
    #expect(names[110] == "BeginTimeout")

    let code: [UInt8] = [0xe3, 97, 0xff, 0xfe, 89, 0, 4, 98, 0, 1, 0, 2]
    let function = try decode(2, code, strict: true)
    try #require(function.instructions.count >= 4)
    #expect(function.instructions[0].operands.first?.value == 3, "compact literal")
    #expect(function.instructions[1].operands.first?.value == -2, "extended literal")
    #expect(function.instructions[2].operands.first?.value == 9, "jump target")
    #expect(function.instructions[3].operands.count == 2, "parent variable operands")
}

@Test func `truncated operand`() throws {
    let function = try decode(2, [97, 0], strict: false)
    #expect(function.diagnostics.count == 1)
    // The diagnostic says where: the function, the instruction, its opcode.
    let diagnostic = try #require(function.diagnostics.first)
    #expect(diagnostic.stage == .decode)
    #expect(diagnostic.function == 2 && diagnostic.offset == 0 && diagnostic.opcode == 97)
    #expect(throws: (any Error).self, "strict decode accepted truncated operand") {
        try decode(2, [97, 0], strict: true)
    }
}

@Test func `opcode numeric contracts`() throws {
    let expected: [UInt8: String] = [
        0: "Equal", 12: "MessageSend", 15: "Return", 18: "Tell",
        21: "Error", 29: "TestIf", 30: "Add", 31: "Subtract",
        32: "Multiply", 33: "Divide", 34: "Quotient", 35: "Remainder",
        36: "Power", 37: "Concatenate", 38: "Coerce", 39: "Negate",
        40: "GetData", 71: "CopyData", 89: "Jump",
        97: "PushLiteralExtended", 110: "BeginTimeout",
    ]
    let names = Opcode.names
    try #require(names.count == 256)
    for (opcode, want) in expected.sorted(by: { $0.key < $1.key }) {
        #expect(names[Int(opcode)] == want, "opcode 0x\(String(opcode, radix: 16))")
    }
    // An object specifier opcode is its suboperation number plus 23.
    let specifiers: [UInt8: UInt8] = [
        21: 44, 22: 45, 24: 47, 25: 48, 27: 50, 30: 53, 31: 54, 32: 55,
    ]
    for (suboperation, opcode) in specifiers.sorted(by: { $0.key < $1.key }) {
        #expect(names[Int(opcode)] == "MakeObjectAlias", "specifier suboperation \(suboperation) has opcode \(opcode)")
        #expect(opcode - 23 == suboperation, "specifier suboperation \(suboperation) has opcode \(opcode)")
    }
}

@Test func `every operand family`() throws {
    let code: [UInt8] = [
        12, 0, 1, // message literal
        43, 0, 2, // positional message literal
        75, 0, 3, // actor literal
        93, 0, 4, // extended variable
        27, 0, 5, // repeat collection variable
        98, 0, 2, 0, 6, // parent depth and variable
        88, 0, 7, 0, 8, // error binding literals
        29, 0, 3, // branch target
        18, 0xff, 0xfe, // signed tell word
        23, 0, 2, // link-repeat relative to operand start
        76, 0, 9, // procedure word
        0xaf, // compact variable
        0xbf, // compact pop variable
        0xcf, // compact global
        0xdf, // compact pop global
        0xff, // compact literal
    ]
    let decoded = try decode(4, code, strict: true)
    try #require(decoded.instructions.count == 16)

    let checks: [(instruction: Int, kinds: [OperandKind], values: [Int])] = [
        (0, [.literalIndex], [1]),
        (3, [.variableIndex], [4]),
        (5, [.parentDepth, .variableIndex], [2, 6]),
        (6, [.literalIndex, .literalIndex], [7, 8]),
        (7, [.branchTarget], [29]),
        (8, [.signedWord], [-2]),
        (11, [.variableIndex], [15]),
        (13, [.literalIndex], [15]),
        (15, [.literalIndex], [15]),
    ]
    for check in checks {
        let got = decoded.instructions[check.instruction].operands
        try #require(got.count == check.kinds.count, "instruction \(check.instruction) operands = \(got)")
        for index in got.indices {
            let want = Operand(kind: check.kinds[index], value: check.values[index])
            #expect(got[index] == want, "instruction \(check.instruction) operand \(index)")
        }
    }
}

/** Opcodes whose 16-bit operand was checked against Apple's framework. */
@Test func `framework verified word operands`() throws {
    let tests: [(opcode: UInt8, kind: OperandKind, value: Int)] = [
        (16, .literalIndex, 0x123), // Continue
        (74, .literalIndex, 0x123), // PositionalContinue
        (77, .literalIndex, 0x123), // DefineClosure
        (78, .literalIndex, 0x123), // DefineProperty
        (82, .branchTarget, 0x124), // Of
        (112, .branchTarget, 0x124), // BeginTransaction
        (117, .literalIndex, 0x123), // MatchLiteral
    ]
    for test in tests {
        let decoded = try decode(0, [test.opcode, 0x01, 0x23, 0x0f], strict: true)
        try #require(decoded.instructions.count == 2, "opcode \(test.opcode) instruction boundaries")
        try #require(decoded.instructions[0].raw.count == 3, "opcode \(test.opcode) instruction boundaries")
        let operand = try #require(decoded.instructions[0].operands.first, "opcode \(test.opcode) has no operand")
        #expect(operand == Operand(kind: test.kind, value: test.value), "opcode \(test.opcode)")
    }
}

// MARK: - The bytes of an instruction, and a limit on their number

/**
 An instruction keeps its bytes in one word, not in an array of its
 own: `raw` gives them back, and `length` is their number.
 */
@Test func `an instruction keeps its bytes`() throws {
    // PushParentVariable has two operand words: five bytes, the longest instruction.
    let decoded = try decode(0, [0x62, 0x00, 0x01, 0xff, 0xfe, 0x0c, 0x00, 0x03, 0x0f], strict: true)
    #expect(decoded.instructions.map(\.raw) == [[0x62, 0x00, 0x01, 0xff, 0xfe], [0x0c, 0x00, 0x03], [0x0f]])
    #expect(decoded.instructions.map(\.length) == [5, 3, 1])
    // Code that is cut in the middle of an operand: the bytes that are left.
    let cut = try decode(0, [0x0f, 0x62, 0x00, 0x01, 0xff], strict: false)
    #expect(cut.instructions.map(\.raw) == [[0x0f], [0x62, 0x00, 0x01, 0xff]])
    #expect(cut.instructions.last?.missingOperands == 1)

    var instruction = Instruction(offset: 0, byte: 0x0f, opcode: .return)
    #expect(instruction.raw.isEmpty && instruction.length == 0)
    instruction.raw = [1, 2, 3]
    #expect(instruction.raw == [1, 2, 3])
    // Seven bytes are kept at most: no instruction is that long.
    instruction.raw = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    #expect(instruction.raw == [1, 2, 3, 4, 5, 6, 7] && instruction.length == 7)
    instruction.takeBytes([9, 8, 7, 6], 1 ..< 3)
    #expect(instruction.raw == [8, 7])
}

/**
 A caller can ask for a number of instructions at most. What is made
 from an instruction takes far more memory than its bytes, so the
 decompiler does not read code without end.
 */
@Test func `decoding stops at the limit it is given`() throws {
    let code: [UInt8] = [0xe0, 0x4f, 0xe1, 0x4f, 0x0f]
    let whole = try decode(7, code, strict: true)
    #expect(whole.instructions.count == 5 && !whole.isCut)
    #expect(try decode(7, code, strict: true, limit: 5).isCut == false)
    let cut = try decode(7, code, strict: true, limit: 3)
    #expect(cut.isCut && cut.instructions.map(\.offset) == [0, 1, 2] && cut.diagnostics.isEmpty && cut.offset == 7)
    let none = try decode(7, code, strict: true, limit: 0)
    #expect(none.isCut && none.instructions.isEmpty)
    // Code that is all read is not cut, even with no instruction left to give.
    #expect(try decode(7, [], strict: true, limit: 0).isCut == false)
}
