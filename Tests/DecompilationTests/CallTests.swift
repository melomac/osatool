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
 A `continue` is first an expression, because its result can be used.
 It becomes the `Continue` statement only when nothing uses it.
 */
@Test func `positional continue builds an expression, then a statement`() throws {
    let s = try contractState(bytes("nextHandler"))
    s.stack = [
        Me(),
        NumberLiteral(integer: 7),
        NumberLiteral(integer: 1),
        It(),
    ]
    let operand = Operand(kind: .literalIndex, value: 0)
    try s.instruction(instruction(74, "PositionalContinue", 0, operand))
    #expect(s.handler.body.isEmpty)
    let expression = try #require(s.stack.last as? ContinueExpr, "continue expression")
    let call = expression.call as? HandlerCall
    try #require(
        call != nil && call?.name == "nextHandler" && call?.target == nil && call?.arguments.count == 1,
        "continue",
    )

    s.flushExpression()
    let statement = try #require(s.handler.body.first as? Continue, "continue statement")
    #expect(statement.call === expression.call)
    #expect(s.stack.isEmpty)
}

/**
 The event form keeps the count under the direct parameter:
 `me, label, value, count, direct parameter`.
 */
@Test func `event continue reads the count below the direct parameter`() throws {
    let s = try contractState(eventIdentifier("aevt", "odoc"))
    s.stack = [
        NumberLiteral(integer: 1),
        Me(),
        Keyword(code: .four("kfil")),
        Variable(name: "second"),
        NumberLiteral(integer: 2),
        Variable(name: "first"),
    ]
    try s.instruction(instruction(16, "Continue", 0, Operand(kind: .literalIndex, value: 0)))
    // Only the values of the `continue` are used: the 1 below them stays.
    try #require(s.stack.count == 2)
    #expect((s.stack[0] as? NumberLiteral)?.integer == 1)
    let call = try #require((s.stack[1] as? ContinueExpr)?.call as? CommandCall)
    #expect(String(decoding: call.code.bytes, as: UTF8.self) == "aevtodoc")
    try #require(call.arguments.count == 2)
    #expect(((call.arguments[0] as? DirectArgument)?.value as? Variable)?.name == "first")
    #expect(((call.arguments[1] as? NamedArgument)?.value as? Variable)?.name == "second")
}

/** A handler without parameters is continued with the event form and its name. */
@Test func `event continue of a user handler without parameters`() throws {
    let s = try contractState(bytes("describe"))
    s.stack = [Me(), NumberLiteral(integer: 0), It()]
    try s.instruction(instruction(16, "Continue", 0, Operand(kind: .literalIndex, value: 0)))
    let call = try #require((s.stack.last as? ContinueExpr)?.call as? HandlerCall)
    #expect(call.name == "describe" && call.target == nil && call.arguments.isEmpty)
    #expect(s.stack.count == 1)
}

@Test func `message event code contracts`() {
    let want = EventCode(bytes: Array("coregetd".utf8))
    let values: [Value] = [
        bytes("coregetd"),
        eventIdentifier("core", "getd"),
        .vector(Vector(children: [.null, bytes("coregetd")])),
    ]
    for value in values {
        let got = value.eventCode
        #expect(got != nil && got == want, "event code from \(value.typeName)")
    }
}

@Test func `event identifier message send`() throws {
    let s = try contractState(eventIdentifier("core", "getd"))
    s.stack = [It(), NumberLiteral()]
    s.message(0, false)
    let command = try #require(s.pop() as? CommandCall)
    #expect(String(decoding: command.code.bytes, as: UTF8.self) == "coregetd")
}

/**
 A byte string is the name of a user handler. Eight letters do not make
 it an event code: `describe` is a name, not `«event describe»`.
 */
@Test func `a byte string message name is a user handler`() throws {
    let s = try contractState(bytes("describe"))
    s.stack = [It(), NumberLiteral()]
    s.message(0, false)
    let call = try #require(s.pop() as? HandlerCall)
    #expect(call.name == "describe" && call.target == nil && call.arguments.isEmpty)
}

/**
 A call with labels: the direct parameter is at the bottom (`it` when
 there is none), then each label and its value, then the count.
 */
@Test func `labeled message send to a user handler`() throws {
    let s = try contractState(bytes("findNumbers"))
    s.stack = [
        Variable(name: "first"),
        Keyword(code: .four("abve")),
        NumberLiteral(integer: 1),
        StringLiteral(value: "rounding"),
        BooleanLiteral(value: true),
        NumberLiteral(integer: 4),
    ]
    s.message(0, false)
    let call = try #require(s.pop() as? LabeledCall)
    #expect(call.name == "findNumbers")
    #expect((call.direct as? Variable)?.name == "first")
    try #require(call.arguments.count == 2)
    #expect(call.arguments[0].label == .code(Code4(bytes: "abve".utf8)))
    #expect(call.arguments[1].label == .word("rounding"))
    #expect(s.stack.isEmpty)

    // Without a direct parameter the compiler pushes `it`.
    s.stack = [It(), Keyword(code: .four("to  ")), NumberLiteral(integer: 5), NumberLiteral(integer: 2)]
    s.message(0, false)
    let second = try #require(s.pop() as? LabeledCall)
    #expect(second.direct == nil && second.arguments.count == 1)
}

/** `continue spread of first by second`: the labels are above `me`, the direct parameter on top. */
@Test func `labeled continue of a user handler`() throws {
    let s = try contractState(bytes("spread"))
    s.stack = [
        Me(),
        Keyword(code: .four("by  ")),
        Variable(name: "second"),
        NumberLiteral(integer: 2),
        Variable(name: "first"),
    ]
    try s.instruction(instruction(16, "Continue", 0, Operand(kind: .literalIndex, value: 0)))
    let call = try #require((s.stack.last as? ContinueExpr)?.call as? LabeledCall)
    #expect(call.name == "spread")
    #expect((call.direct as? Variable)?.name == "first")
    #expect(call.arguments.count == 1 && call.arguments[0].label == .code(Code4(bytes: "by  ".utf8)))
    #expect((call.arguments[0].value as? Variable)?.name == "second")
    #expect(s.stack.count == 1)
}

@Test func `message send preserves explicit me argument`() throws {
    let event = eventIdentifier("ears", "ffdr")
    let s = try contractState(event)
    s.stack = [Me(), NumberLiteral()]
    s.message(0, false)
    let command = try #require(s.pop() as? CommandCall)
    try #require(command.arguments.count == 1, "arguments, want explicit me")
    let direct = try #require(command.arguments[0] as? DirectArgument, "argument")
    try #require(direct.value is Me, "direct value, want me")
}

@Test func `typed argument contracts`() throws {
    let terms = try Registry.default()
    let event = try EventCode(parsing: "sysoexec")
    let values: [any Expr?] = [
        StringLiteral(value: "id"),
        Keyword(code: .four("badm")),
        BooleanLiteral(value: true),
    ]
    let arguments = try #require(terms.command(event)).arguments(values)
    try #require(arguments.count == 2, "arguments")
    try #require(arguments[0] is DirectArgument, "direct argument")
    let flag = arguments[1] as? FlagArgument
    try #require(
        flag != nil && flag?.name == "administrator privileges" && flag?.enabled == true,
        "flag argument",
    )
}
