import AST
import Bytecode
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Terminology
import Testing

/**
 Builds the state of one handler named `test`, with the default
 terminology.

 The function has 64 bytes of code, so an instruction at a small offset
 is never the last one. There are two variables and three parent scopes;
 the second scope is empty.
 */
func contractState(_ literals: Value...) throws -> State {
    let terms = try Registry.default()
    let script = CompiledScript()
    let decompiler = Decompiler(script: script, options: RebuildOptions(terms: terms))
    let function = Function(offset: 2, literals: literals, code: [UInt8](repeating: 0, count: 64))
    let handler = Handler(name: "test")
    return State(
        decompiler: decompiler, function: function, handler: handler,
        variables: ["first", "second"],
        parentScopes: [["outer0", "outer1"], [], ["far0", "far1"]],
    )
}

/** Gives operands from a list. A branch operand is already the place it leads to. */
struct OperandList: OperandSource {
    var values: [Int]

    mutating func word() -> Int {
        self.values.isEmpty ? 0 : self.values.removeFirst()
    }

    mutating func target() -> Int {
        self.word()
    }
}

/**
 Builds one instruction from its opcode byte and its operands. Its raw
 bytes are the opcode byte alone.

 `mnemonic` is the name of the byte, written in the test so that it can
 be read. It is checked against the opcode table.
 */
func instruction(_ byte: UInt8, _ mnemonic: String, _ offset: Int, _ operands: Operand...) -> Instruction {
    var source = OperandList(values: operands.map(\.value))
    let instruction = Instruction(offset: offset, byte: byte, opcode: Opcode(byte: byte, operands: &source), raw: [byte])
    #expect(instruction.mnemonic == mnemonic, "byte \(byte) is \(instruction.mnemonic)")
    #expect(instruction.operands == operands, "operands of \(mnemonic)")
    return instruction
}

/** Returns a byte string value holding the UTF-8 bytes of `text`. */
func bytes(_ text: String) -> Value {
    .bytes(Array(text.utf8))
}

/**
 Returns an event identifier, in its object wrapper, with its two first
 fields set: event class and event ID.
 */
func eventIdentifier(_ eventClass: String, _ eventID: String) -> Value {
    var event = EventIdentifier()
    event.fields[0] = Code4(bytes: eventClass.utf8)
    event.fields[1] = Code4(bytes: eventID.utf8)
    return .object(.eventIdentifier(event))
}

/** Returns a stored four-character code. */
func code(_ text: String) -> Value {
    .object(.constant(UInt64(Code4(bytes: text.utf8).rawValue)))
}
