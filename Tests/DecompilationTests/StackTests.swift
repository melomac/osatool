import AST
import Bytecode
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Terminology
import Testing

@Test func `literal and parent index guards`() throws {
    let s = try contractState(bytes("first"), bytes("last"))
    try #require(try #require(s.literal(-1) as? Variable).name == "literal_-1", "negative literal")
    try #require(try #require(s.literal(1) as? StringLiteral).value == "last", "valid literal")
    try #require(try #require(s.literal(2) as? Variable).name == "literal_2", "out-of-range literal")
    try #require(s.parentVariable(2, 1) == "far1", "parent variable across empty scope")
}

@Test func `stack bookkeeping contracts`() throws {
    let s = try contractState()
    let first = Variable(name: "first")
    let second = Variable(name: "second")
    s.stack = [first, second]
    try s.instruction(instruction(92, "GCSwap", 0))
    try #require(s.stack[0] === second && s.stack[1] === first, "swap")
    try s.instruction(instruction(90, "Pop", 1))
    try #require(s.stack.count == 1 && s.stack[0] === second, "pop")
    try s.instruction(instruction(91, "Dup", 2))
    try #require(s.stack.count == 2 && s.stack[0] === s.stack[1], "dup")
}

@Test func `stack underflow is explicit`() throws {
    let s = try contractState()
    let value = s.pop()
    try #require(value is MissingLiteral && s.underflow, "underflow was not recorded")
}

@Test func `source free result opcodes emit nothing`() throws {
    let s = try contractState()
    let value = NumberLiteral(integer: 7)
    s.stack = [value]
    for (byte, mnemonic) in [(UInt8(40), "GetData"), (69, "GetData")] {
        try s.instruction(instruction(byte, mnemonic, 0))
    }
    try #require(
        s.stack.count == 1 && s.stack[0] === value && s.handler.body.isEmpty,
        "source-free opcode changed state",
    )
}

/** `GetResult` is the empty line that ends a block: it is a statement, and the stack stays as it is. */
@Test func `get result is an empty line`() throws {
    let s = try contractState()
    let value = NumberLiteral(integer: 7)
    s.stack = [value]
    try s.instruction(instruction(80, "GetResult", 0))
    try #require(s.stack.count == 1 && s.stack[0] === value, "the stack changed")
    try #require(s.handler.body.count == 1 && s.handler.body[0] is Blank, "no empty line")
}

@Test func `store result discards compiler duplicate`() throws {
    let s = try contractState()
    let value = NumberLiteral(integer: 7)
    s.stack = [value, value]
    try s.instruction(instruction(79, "StoreResult", 0))
    try #require(s.stack.isEmpty && s.handler.body.count == 1, "store result left duplicate")
    let expression = s.handler.body[0] as? AST.Expression
    try #require(expression != nil && expression?.value === value, "stored result")
}

@Test func `undefined control marker does not displace expression values`() throws {
    let s = try contractState()
    try s.instruction(instruction(104, "PushUndefined", 0))
    s.push(NumberLiteral(integer: 2))
    s.pending = Variable(name: "answer")
    try s.instruction(instruction(79, "StoreResult", 1))
    try #require(s.handler.body.count == 1 && s.stack.isEmpty, "marker displaced result")
    try s.instruction(instruction(79, "StoreResult", 2))
    try #require(s.handler.body.count == 1 && s.stack.isEmpty, "the marker became a statement")
}

@Test func `unsupported opcode is explicit`() throws {
    let s = try contractState()
    #expect(throws: (any Error).self, "unsupported opcode did not return an error") {
        try s.instruction(instruction(0x72, "Undefined", 0))
    }
}
