import AST
import Bytecode
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Terminology
import Testing

@Test func `transaction and of opcodes build structured AST`() throws {
    let s = try contractState()
    let branch = Operand(kind: .branchTarget, value: 10)
    try s.instruction(instruction(112, "BeginTransaction", 0, branch))
    s.emit(AST.Expression(value: Variable(name: "work")))
    try s.instruction(instruction(113, "EndTransaction", 9))
    let transaction = s.handler.body.first as? Transaction
    try #require(transaction != nil && transaction?.body.count == 1, "transaction")

    s.stack = [Variable(name: "container")]
    try s.instruction(instruction(82, "Of", 10, branch))
    s.push(Variable(name: "property"))
    try s.instruction(instruction(84, "EndOf", 11))
    let of = try #require(s.pop() as? Binary, "of expression")
    let ofLeft = try #require(of.left as? Variable, "of expression")
    let ofRight = try #require(of.right as? Variable, "of expression")
    try #require(of.op == .of && ofLeft.name == "property" && ofRight.name == "container", "of expression")
}

/**
 Three cases. Each one is a block with its own state, so a failure in one
 block does not stop the next blocks.
 */
@Test func `block boundary attachment contracts`() throws {
    do {
        // shared-boundary-stays-in-then
        let s = try contractState()
        let parent = If(condition: BooleanLiteral(value: true))
        let child = If(condition: BooleanLiteral(value: true))
        s.blocks.append(contentsOf: [
            Block(.if(parent), elseAt: 10),
            Block(.if(child), elseAt: 10),
        ])
        s.closeAt(10)
        #expect(
            parent.then.count == 1 && parent.then[0] === child && parent.else.isEmpty,
            "shared-boundary-stays-in-then",
        )
    }
    do {
        // child-at-else-boundary-stays-in-then
        let s = try contractState()
        let parent = If(condition: BooleanLiteral(value: true))
        let child = Repeat(kind: .forever)
        s.blocks.append(contentsOf: [
            Block(.if(parent), elseAt: 10, endAt: 20),
            Block(.repeat(child), endAt: 10),
        ])
        s.closeAt(10)
        #expect(
            parent.then.count == 1 && parent.then[0] === child && parent.else.isEmpty,
            "child-at-else-boundary-stays-in-then",
        )
    }
    do {
        // after-else-target-goes-in-else
        let s = try contractState()
        let parent = If(condition: BooleanLiteral(value: true))
        s.blocks.append(Block(.if(parent), elseAt: 10, endAt: 20))
        s.closeAt(10)
        let statement = Return(explicit: true)
        s.emit(statement)
        #expect(
            parent.then.isEmpty && parent.else.count == 1 && parent.else[0] === statement,
            "after-else-target-goes-in-else",
        )
    }
}

@Test func `current application tell preserves expression result`() throws {
    let s = try contractState()
    let call = CommandCall(name: "ASCII character", arguments: [
        DirectArgument(value: NumberLiteral(integer: 65)),
    ])
    let tell = Tell(target: CurrentApplication())
    // With `use scripting additions`, the compiler adds this tell by itself.
    s.decompiler.usesScriptingAdditions = true
    s.blocks.append(Block(.tell(tell)))
    s.stack = [call]
    try s.instruction(instruction(85, "EndTell", 0))
    try #require(s.stack.count == 1 && s.stack[0] === call, "implicit tell consumed expression result")
    try #require(s.handler.body.isEmpty, "implicit tell emitted source statements")
}

/** Without `use scripting additions`, the same tell was written by the author: it is kept. */
@Test func `current application tell of the source is kept`() throws {
    let s = try contractState()
    let call = CommandCall(name: "beep")
    let tell = Tell(target: CurrentApplication())
    s.blocks.append(Block(.tell(tell)))
    s.stack = [call]
    try s.instruction(instruction(85, "EndTell", 0))
    #expect(s.stack.isEmpty)
    #expect(s.handler.body.first === tell)
    #expect((tell.body.first as? AST.Expression)?.value === call)
}

@Test func `error boundary keeps general expression inside try`() throws {
    let s = try contractState()
    let node = Try()
    s.blocks.append(Block(.try(node)))
    let expression = Binary(op: .add, left: NumberLiteral(integer: 1), right: NumberLiteral(integer: 2))
    s.stack = [expression]
    let inst = instruction(87, "EndErrorHandler", 0, Operand(kind: .branchTarget, value: 10))
    try s.instruction(inst)
    try #require(node.body.count == 1, "try body")
    try #require(try #require(node.body[0] as? AST.Expression, "try body").value === expression, "try body")
}

@Test func `copy and return boundary contracts`() throws {
    var s = try contractState()
    let source = Variable(name: "oldValue")
    let target = Variable(name: "newValue")
    s.stack = [source, target]
    try s.instruction(instruction(71, "CopyData", 0))
    let copyStatement = s.handler.body.first as? Copy
    try #require(
        copyStatement != nil && copyStatement?.source === source && copyStatement?.target === target,
        "copy",
    )

    s = try contractState()
    s.pending = target
    s.stack = [source]
    try s.instruction(instruction(15, "Return", 1))
    let set = s.handler.body.first as? SetStmt
    try #require(set != nil && set?.target === target && set?.value === source, "return assignment")

    s = try contractState()
    try s.instruction(instruction(15, "Return", 1))
    try #require(s.handler.body.first is Return, "bare return")
}

@Test func `error opcode stack order`() throws {
    let s = try contractState()
    s.stack = [
        Me(),
        Keyword(code: .four("errn")),
        NumberLiteral(integer: 42),
        NumberLiteral(integer: 2),
        StringLiteral(value: "boom"),
    ]
    try s.instruction(instruction(21, "Error", 0))
    let command = try #require(s.handler.body.first as? ErrorStmt)
    try #require(command.arguments.count == 2, "error statement")
    let direct = try #require(command.arguments[0] as? DirectArgument)
    let message = try #require(direct.value as? StringLiteral).value
    try #require(message == "boom", "error message")
    let named = try #require(command.arguments[1] as? NamedArgument)
    let number = try #require(named.value as? NumberLiteral)
    try #require(String(decoding: named.code.bytes, as: UTF8.self) == "errn" && number.integer == 42, "error named argument")
}

/**
 The parts of an `on error` line are a chain: one link for each part,
 with the code of its label, in the order of the source.
 */
@Test func `the on error line is read from its chain`() throws {
    func link(_ code: Code4, _ value: Value, _ next: Value = .null) -> Value {
        .binding(Binding(key: .object(.constant(UInt64(code.rawValue))), value: value, next: next))
    }
    let chain = link("errn", bytes("n"), link("erob", bytes("f"), link("errt", bytes("c"), link("ptlr", bytes("p")))))
    let s = try contractState(bytes("messageText"), chain, link("errn", .integer(-128)), .binding(Binding(value: bytes("legacy"))))
    func handle(_ parts: Int) throws -> Try {
        let node = Try()
        s.blocks.append(Block(.try(node)))
        try s.instruction(instruction(
            88, "HandleError", 0, Operand(kind: .literalIndex, value: 0), Operand(kind: .literalIndex, value: parts),
        ))
        return node
    }
    let all = try handle(1)
    #expect(all.errorName == "messageText")
    #expect(all.parameters.map(\.label) == [.number, .from, .to, .partialResult])
    #expect(all.parameters.map { ($0.value as? Variable)?.name } == ["n", "f", "c", "p"])
    #expect(all.names == ["messageText", "n", "f", "c", "p"])

    // `on error number -128`: a number in place of the variable.
    let filter = try handle(2)
    #expect(filter.parameters.count == 1)
    #expect((filter.parameters.first?.value as? NumberLiteral)?.integer == -128)

    // A link without a code is the number.
    let legacy = try handle(3)
    #expect(legacy.parameters.map(\.label) == [.number])
}

@Test func `consideration option recovery`() throws {
    let terms = try Registry.default()
    let got = Keyword(code: .four("nume")).considerationNames(terms)
    try #require(got.count == 1 && got[0] == "numeric strings", "consideration names")
    let s = try contractState()
    s.stack = [
        Keyword(code: .four("nume")),
        List(),
    ]
    let inst = instruction(19, "Consider", 0, Operand(kind: .branchTarget, value: 10))
    try s.instruction(inst)
    let node = try #require(s.blocks[s.blocks.count - 1].scope.considerNode)
    try #require(node.options.count == 1 && node.options[0] == "numeric strings", "consider block")
}

/**
 `error number -128` has no message: the compiler writes
 `PushUndefined` where the message would be.
 */
@Test func `an error statement can have no message`() throws {
    let s = try contractState()
    s.stack = [Me(), Keyword(code: .four("errn")), NumberLiteral(integer: -128), NumberLiteral(integer: 2)]
    try s.instruction(instruction(104, "PushUndefined", 0))
    s.previous = .pushUndefined
    try s.instruction(instruction(21, "Error", 1))
    let statement = try #require(s.handler.body.first as? ErrorStmt)
    #expect(statement.arguments.count == 1)
    let number = try #require(statement.arguments.first as? NamedArgument)
    #expect(number.code == "errn")
    #expect((number.value as? NumberLiteral)?.integer == -128)
    #expect(s.stack.isEmpty)
}
