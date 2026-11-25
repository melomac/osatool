import Bytecode
import Foundation
import Testing
import TestSupport

/** Prints the operands of an instruction as the listing does: `kind=value`. */
private func operandText(_ instruction: Instruction) -> String {
    let text = instruction.operands.map { "\($0.kind.rawValue)=\($0.value)" }.joined(separator: " ")
    return text.isEmpty ? "-" : text
}

/**
 Returns one line for an opcode byte: how it decodes when four operand
 bytes follow it, and how it decodes when the code is cut after 0 and
 after 3 operand bytes.

 ```
 62  PushParentVariable   5  parent-depth=291 variable-index=1110  | cut: 1 - | 4 parent-depth=291
 ```

 The columns are the byte, the mnemonic, the length of the instruction
 and its operands. After `cut:` come the length and the operands of the
 instruction that is kept for each cut-off code.
 */
private func tableLine(_ byte: UInt8) throws -> String {
    let complete = try decode(2, [byte, 0x01, 0x23, 0x04, 0x56], strict: false)
    let first = try #require(complete.instructions.first)
    var line = String(byte, radix: 16).leftPadded(2) + "  " + first.mnemonic.rightPadded(22)
    line += " \(first.raw.count)  " + operandText(first)
    line += "  | cut:"
    for code in [[byte], [byte, 0x01, 0x23, 0x04]] {
        let cut = try decode(2, code, strict: false)
        let kept = try #require(cut.instructions.first)
        line += " \(kept.raw.count) \(operandText(kept))" + (cut.diagnostics.isEmpty ? "" : " !") + (code.count == 1 ? " |" : "")
    }
    return line
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        String(repeating: "0", count: max(0, width - self.count)) + self
    }

    func rightPadded(_ width: Int) -> String {
        self + String(repeating: " ", count: max(0, width - self.count))
    }
}

/** Gives the words 1, 2, 3, … and counts how many were asked for. */
private struct CountingSource: OperandSource {
    var count = 0

    mutating func word() -> Int {
        self.count += 1
        return self.count
    }

    mutating func target() -> Int {
        self.word()
    }
}

@Test func `opcode bytes select typed cases`() {
    func opcode(_ byte: UInt8) -> Opcode {
        var source = CountingSource()
        return Opcode(byte: byte, operands: &source)
    }
    #expect(opcode(0) == .binary(.equal))
    #expect(opcode(37) == .binary(.concatenate))
    #expect(opcode(9) == .and(end: 1))
    #expect(opcode(12) == .messageSend(literal: 1))
    #expect(opcode(47) == .makeObjectAlias(form: .index))
    // The twelve forms have the twelve bytes from 44 to 55.
    #expect(SpecifierForm.allCases.map(\.rawValue) == Array(44 ... 55))
    #expect(opcode(56) == .makeComp(index: 0))
    #expect(opcode(88) == .handleError(message: 1, number: 2))
    #expect(opcode(98) == .pushParentVariable(depth: 1, index: 2))
    #expect(opcode(105) == .pushInteger(-1))
    #expect(opcode(109) == .pushInteger(3))
    #expect(opcode(114) == .invalid)
    #expect(opcode(120) == .invalid)

    // The short form and the long form of an opcode are the same case.
    #expect(opcode(97) == .pushLiteral(1))
    #expect(opcode(0xe1) == .pushLiteral(1))
    #expect(opcode(93) == .pushVariable(1))
    #expect(opcode(0xa1) == .pushVariable(1))
    #expect(opcode(0xb1) == .popVariable(1))
    #expect(opcode(95) == .pushGlobal(literal: 1))
    #expect(opcode(0xc1) == .pushGlobal(literal: 1))
    #expect(opcode(0xd1) == .popGlobal(literal: 1))
}

/**
 `Opcode.operands` lists the operands for the listing. It must list one
 operand for each word the opcode reads, and one for the index of a
 short form.
 */
@Test func `listed operands match the words that are read`() {
    for byte in UInt8.min ... UInt8.max {
        var source = CountingSource()
        let opcode = Opcode(byte: byte, operands: &source)
        let short = byte >= 160 ? 1 : 0
        #expect(opcode.operands.count == source.count + short, "byte \(byte)")
        // The values come in the order they were read.
        if byte < 160 {
            #expect(opcode.operands.map(\.value) == Array(1 ..< source.count + 1), "byte \(byte)")
        }
    }
}

@Test func `operator bytes`() {
    #expect(Operator(byte: 0) == .equal)
    #expect(Operator(byte: 8) == .contains)
    #expect(Operator(byte: 30) == .add)
    #expect(Operator(byte: 37) == .concatenate)
    for byte: UInt8 in [9, 10, 11, 29, 38, 255] {
        #expect(Operator(byte: byte) == nil, "byte \(byte)")
    }
}

/** An operand that is cut off is 0 in the opcode, and is not listed. */
@Test func `cut-off operands are zero and not listed`() throws {
    // PushParentVariable with its first word only.
    let decoded = try decode(2, [0x0f, 98, 0x00, 0x05, 0x01], strict: false)
    let last = try #require(decoded.instructions.last)
    #expect(last.opcode == .pushParentVariable(depth: 5, index: 0))
    #expect(last.missingOperands == 1)
    #expect(last.operands == [Operand(kind: .parentDepth, value: 5)])
    #expect(last.raw == [98, 0x00, 0x05, 0x01])

    // A branch that is cut off leads to 0, not to its own position.
    let branch = try decode(2, [89, 0x00], strict: false)
    #expect(branch.instructions.first?.opcode == .jump(target: 0))
    #expect(branch.instructions.first?.operands.isEmpty == true)
}

/**
 The decoding of every opcode byte is kept in
 `testdata/snapshots/opcodes.txt`. A change to the opcode table or to
 the decoder that changes one line must be wanted.

 To write the file again, run the tests with the environment variable
 `OSATOOL_WRITE_OPCODES` set.
 */
@Test func `every opcode byte decodes as in the reference table`() throws {
    let table = try (0 ... 255).map { try tableLine(UInt8($0)) }.joined(separator: "\n") + "\n"
    if ProcessInfo.processInfo.environment["OSATOOL_WRITE_OPCODES"] != nil {
        try Data(table.utf8).write(to: TestData.url("snapshots/opcodes.txt"))
    }
    let expected = try TestData.text("snapshots/opcodes.txt")
    let got = table.split(separator: "\n")
    let want = expected.split(separator: "\n")
    try #require(got.count == want.count)
    for (gotLine, wantLine) in zip(got, want) {
        #expect(gotLine == wantLine)
    }
}
