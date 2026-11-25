@testable import AST
import Extensions
import Terminology
import Testing

@Test func `every repeat header`() throws {
    let f = try contractFormatter()
    let cases: [(node: Repeat, want: String)] = [
        (Repeat(kind: .forever), "repeat\nend repeat"),
        (Repeat(kind: .while, condition: BooleanLiteral(value: true), body: [ExitRepeat()]), "repeat while true\n    exit repeat\nend repeat"),
        (Repeat(kind: .until, condition: BooleanLiteral()), "repeat until false\nend repeat"),
        (Repeat(kind: .times, times: NumberLiteral(integer: 3)), "repeat 3 times\nend repeat"),
        (Repeat(kind: .range, variable: "i", from: NumberLiteral(integer: 1), to: NumberLiteral(integer: 4)), "repeat with i from 1 to 4\nend repeat"),
        (Repeat(kind: .range, variable: "i", from: NumberLiteral(integer: 1), to: NumberLiteral(integer: 5), by: NumberLiteral(integer: 2)), "repeat with i from 1 to 5 by 2\nend repeat"),
        (Repeat(kind: .in, variable: "i", collection: List(elements: [NumberLiteral(integer: 1)])), "repeat with i in {1}\nend repeat"),
    ]
    for test in cases {
        let got = f.stmt(test.node, 0)
        #expect(got == test.want, "repeat = \(got), want \(test.want)")
    }
}

@Test func `transaction continue and opaque rendering`() throws {
    let f = try contractFormatter()
    let transaction = Transaction(body: [Continue(call: HandlerCall(
        name: "nextHandler", arguments: [NumberLiteral(integer: 7)],
    ))])
    let want = "with transaction\n    continue nextHandler(7)\nend transaction"
    let got = f.stmt(transaction, 0)
    try #require(got == want, "transaction = \(got), want \(want)")
    let opaque = f.expr(OpaqueLiteral(runtimeType: 254, data: [0xaa, 0xbb]))
    try #require(opaque == "«unsupported runtime data type 254: aabb»", "opaque literal = \(opaque)")
}

@Test func `if try and error binding rendering`() throws {
    let node = Try(
        body: [If(
            condition: BooleanLiteral(value: true),
            then: [SetStmt(target: Variable(name: "answer"), value: NumberLiteral(integer: 1))],
            else: [Return(value: NumberLiteral(), explicit: true)],
        )],
        errorName: "messageText",
        parameters: [ErrorParameter(.number, Variable(name: "numberValue"))],
        errorBody: [Return(value: Variable(name: "numberValue"), explicit: true)],
    )
    let want = "try\n" +
        "    if true then\n" +
        "        set answer to 1\n" +
        "    else\n" +
        "        return 0\n" +
        "    end if\n" +
        "on error messageText number numberValue\n" +
        "    return numberValue\n" +
        "end try"
    let got = try contractFormatter().stmt(node, 0)
    try #require(got == want, "try =\n\(got)\nwant:\n\(want)")
}

@Test func `extended error binding rendering`() throws {
    let node = Try(
        errorName: "messageText",
        parameters: [
            ErrorParameter(.number, Variable(name: "numberValue")), ErrorParameter(.from, Variable(name: "fromValue")),
            ErrorParameter(.to, Variable(name: "toValue")), ErrorParameter(.partialResult, Variable(name: "partialValue")),
        ],
        errorBody: [Return(value: Variable(name: "numberValue"), explicit: true)],
    )
    let got = try contractFormatter().stmt(node, 0)
    // The parts are printed in the order they have, which is the one of the source.
    let want = "on error messageText number numberValue from fromValue to toValue partial result partialValue"
    try #require(got.contains(want), "try does not contain \(want):\n\(got)")
    // A number in place of a variable: only that error is handled.
    let filter = Try(parameters: [ErrorParameter(.number, NumberLiteral(integer: -128))])
    #expect(try contractFormatter().stmt(filter, 0) == "try\non error number -128\nend try")
}

@Test func `top level expression omits redundant parentheses`() throws {
    let f = try contractFormatter()
    let command = f.expr(CommandCall(name: "path to", arguments: [
        DirectArgument(value: Me()),
    ]), .statement)
    #expect(command == "path to me", "top-level command = \(command)")
    let coercion = f.expr(Coerce(
        value: StringLiteral(value: "value"),
        type: Keyword(fallback: "string"),
    ), .statement)
    #expect(coercion == #""value" as string"#, "top-level coercion = \(coercion)")
}

@Test func `control and copy statement contracts`() throws {
    let node = Considering(options: ["numeric strings"], body: [
        Timeout(seconds: NumberLiteral(integer: 10), body: [
            Copy(source: Variable(name: "originalValues"), target: Variable(name: "clonedValues")),
        ]),
    ])
    let want = "considering numeric strings\n" +
        "    with timeout of 10 seconds\n" +
        "        copy originalValues to clonedValues\n" +
        "    end timeout\n" +
        "end considering"
    let got = try contractFormatter().stmt(node, 0)
    try #require(got == want, "control statement =\n\(got)\nwant:\n\(want)")
}

@Test func `statement forms`() throws {
    let f = try contractFormatter()
    let x = Variable(name: "x")
    func number(_ value: Int64) -> NumberLiteral {
        NumberLiteral(integer: value)
    }

    // A call that is a whole statement has no parentheses around it.
    #expect(f.stmt(Expression(value: CommandCall(name: "beep")), 0) == "beep")
    #expect(f.stmt(Expression(value: LabeledCall(name: "polish", arguments: [LabeledArgument(label: .code("to  "), value: x)])), 0) == "polish to x")
    #expect(f.expr(List(elements: [CommandCall(name: "beep")])) == "{(beep)}")

    // An `else` part that is one `if` is written `else if`.
    let chain = If(
        condition: Binary(op: .equal, left: x, right: number(1)), then: [Return(value: number(1), explicit: true)],
        else: [If(
            condition: Binary(op: .equal, left: x, right: number(2)), then: [Return(value: number(2), explicit: true)],
            else: [Return(value: number(3), explicit: true)],
        )],
    )
    #expect(f.stmt(chain, 0) == """
    if x = 1 then
        return 1
    else if x = 2 then
        return 2
    else
        return 3
    end if
    """)
    // Two statements in the `else` part stay a block.
    let block = If(condition: x, then: [ExitRepeat()], else: [If(condition: x), ExitRepeat()])
    #expect(f.stmt(block, 0) == "if x then\n    exit repeat\nelse\n    if x then\n    end if\n    exit repeat\nend if")

    // A step of 1 is what the compiler stores when the source has none.
    func loop(_ step: any Expr?) -> String {
        f.stmt(Repeat(kind: .range, variable: "i", from: number(1), to: number(3), by: step), 0)
    }
    #expect(loop(number(1)) == "repeat with i from 1 to 3\nend repeat")
    #expect(loop(number(2)) == "repeat with i from 1 to 3 by 2\nend repeat")
    #expect(loop(x) == "repeat with i from 1 to 3 by x\nend repeat")
    #expect(loop(nil) == "repeat with i from 1 to 3\nend repeat")
}
