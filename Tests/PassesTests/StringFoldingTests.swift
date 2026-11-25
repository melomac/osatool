import AST
import Extensions
import Foundation
@testable import Passes
import Terminology
import Testing

@Test func `strings preserves list shape while rewriting elements`() throws {
    let list = List(elements: [
        concatenate(
            StringLiteral(value: "a"),
            StringLiteral(value: "b"),
        ),
        standardCommand(
            "ASCII character",
            "sysontoc",
            DirectArgument(value: NumberLiteral(integer: 65)),
        ),
    ])
    let script = Script(properties: [Property(name: "value", value: list)])
    _ = Strings().rewrite(script)
    let got = try #require(script.properties[0].value as? List)
    try #require(got.elements.count == 2)
    for (index, want) in ["ab", "A"].enumerated() {
        let literal = got.elements[index] as? StringLiteral
        try #require(literal?.value == want, "element \(index)")
    }
}

/** A pass also visits the direct parameter and the values of a call with labels. */
@Test func `strings rewrites the arguments of a labeled call`() {
    let call = LabeledCall(
        name: "spread",
        direct: concatenate(StringLiteral(value: "a"), StringLiteral(value: "b")),
        arguments: [LabeledArgument(label: .word("extra"), value: concatenate(StringLiteral(value: "c"), StringLiteral(value: "d")))],
    )
    let script = Script(handlers: [Handler(body: [Expression(value: call)])])
    _ = Strings().rewrite(script)
    #expect((call.direct as? StringLiteral)?.value == "ab")
    #expect((call.arguments[0].value as? StringLiteral)?.value == "cd")
}

@Test func `strings folds literal assignments and direct text`() throws {
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "_t"),
            value: StringLiteral(value: "example"),
        ),
        SetStmt(
            target: Variable(name: "lib_name"),
            value: concatenate(
                StringLiteral(value: "lib"),
                Variable(name: "_t"),
                StringLiteral(value: "."),
                StringLiteral(value: "d"),
                StringLiteral(value: "y"),
                StringLiteral(value: "l"),
                StringLiteral(value: "i"),
                StringLiteral(value: "b"),
            ),
        ),
        SetStmt(
            target: Variable(name: "base"),
            value: standardCommand("do shell script", "sysoexec"),
        ),
        SetStmt(
            target: Variable(name: "path"),
            value: concatenate(
                Variable(name: "base"),
                StringLiteral(value: "/"),
                StringLiteral(value: "A"),
                StringLiteral(value: "p"),
                StringLiteral(value: "p"),
            ),
        ),
        SetStmt(
            target: Variable(name: "nested"),
            value: concatenate(
                Variable(name: "path"),
                StringLiteral(value: "/"),
                StringLiteral(value: "x"),
            ),
        ),
    ])])

    _ = Strings().rewrite(script)

    let first = try #require(script.handlers[0].body[1] as? SetStmt).value
    try #require((first as? StringLiteral)?.value == "libexample.dylib", "constant propagation")

    let second = try #require(script.handlers[0].body[3] as? SetStmt).value
    var binary = try #require(second as? Binary, "dynamic prefix")
    try #require((binary.left as? Variable)?.name == "base", "dynamic prefix left")
    try #require((binary.right as? StringLiteral)?.value == "/App", "dynamic prefix suffix")

    let nested = try #require(script.handlers[0].body[4] as? SetStmt).value
    binary = try #require(nested as? Binary, "transitive dynamic prefix")
    try #require((binary.left as? Variable)?.name == "path", "transitive dynamic prefix left")
    try #require((binary.right as? StringLiteral)?.value == "/x", "transitive dynamic prefix suffix")
}

@Test func `strings folds ASCII character chain`() throws {
    var expressions: [any Expr] = []
    for character in "open https://example.invalid/".unicodeScalars {
        expressions.append(standardCommand(
            "ASCII character",
            "sysontoc",
            DirectArgument(value: NumberLiteral(integer: Int64(character.value))),
        ))
    }
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "cmd"),
            value: concatenate(expressions),
        ),
    ])])

    _ = Strings().rewrite(script)

    let value = try #require(script.handlers[0].body[0] as? SetStmt).value
    try #require((value as? StringLiteral)?.value == "open https://example.invalid/", "ASCII chain")
}

@Test func `strings refuses unknown concatenation types`() throws {
    let value = concatenate(
        Variable(name: "unknown"),
        StringLiteral(value: "a"),
        StringLiteral(value: "b"),
    )
    let script = Script(handlers: [Handler(body: [
        SetStmt(target: Variable(name: "result"), value: value),
    ])])

    _ = Strings().rewrite(script)

    let got = try #require(script.handlers[0].body[0] as? SetStmt).value
    let outer = try #require(got as? Binary, "unknown concatenation")
    try #require((outer.right as? StringLiteral)?.value == "b", "unknown concatenation was reassociated")
}

@Test func `strings still folds expressions when flow tracking is disabled`() throws {
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "reference"),
            value: Reference(value: Variable(name: "fragment")),
        ),
        SetStmt(
            target: Variable(name: "fragment"),
            value: StringLiteral(value: "dynamic"),
        ),
        SetStmt(
            target: Variable(name: "flow_result"),
            value: concatenate(
                Variable(name: "fragment"),
                StringLiteral(value: "-suffix"),
            ),
        ),
        SetStmt(
            target: Variable(name: "literal_result"),
            value: concatenate(
                StringLiteral(value: "a"),
                StringLiteral(value: "b"),
                standardCommand(
                    "ASCII character",
                    "sysontoc",
                    DirectArgument(value: NumberLiteral(integer: 67)),
                ),
            ),
        ),
    ])])

    _ = Strings().rewrite(script)

    let flow = try #require(script.handlers[0].body[2] as? SetStmt).value
    try #require(flow is Binary, "flow-sensitive value was propagated")
    let value = try #require(script.handlers[0].body[3] as? SetStmt).value
    try #require((value as? StringLiteral)?.value == "abC", "context-free value")
}

@Test func `strings rejects invalid ASCII character arguments`() {
    let tests: [(name: String, number: NumberLiteral)] = [
        ("real", NumberLiteral(real: 65.5, isReal: true)),
        ("surrogate", NumberLiteral(integer: 0xd800)),
        ("negative", NumberLiteral(integer: -1)),
        ("primary-encoding-dependent", NumberLiteral(integer: 128)),
        ("out-of-range", NumberLiteral(integer: 256)),
        ("too-large", NumberLiteral(integer: 0x110000)),
    ]
    for test in tests {
        let call = standardCommand(
            "ASCII character",
            "sysontoc",
            DirectArgument(value: test.number),
        )
        #expect(call.foldedText === call, "\(test.name): invalid ASCII argument was folded")
    }

    // Subtest "foreign-same-name-command".
    let call = standardCommand(
        "ASCII character",
        "fakefake",
        DirectArgument(value: NumberLiteral(integer: 65)),
    )
    #expect(call.foldedText === call, "foreign command was folded")
}

@Test func `infer string recognizes trusted text producers`() {
    func keyword(_ code: String, _ fallback: String) -> Keyword {
        Keyword(code: KeywordCode(bytes: Array(code.utf8)), fallback: fallback)
    }
    let tests: [(name: String, expression: any Expr)] = [
        (
            name: "quoted-form-operator",
            expression: Binary(
                op: .of,
                left: keyword("strq", "quoted form"),
                right: Variable(name: "value"),
            ),
        ),
        (
            name: "posix-path-operator",
            expression: Binary(
                op: .of,
                left: keyword("psxp", "POSIX path"),
                right: Variable(name: "value"),
            ),
        ),
        (
            name: "string-coercion",
            expression: Coerce(
                value: Variable(name: "value"),
                type: keyword("TEXT", "string"),
            ),
        ),
        (
            name: "text-coercion",
            expression: Coerce(
                value: Variable(name: "value"),
                type: keyword("ctxt", "text"),
            ),
        ),
        (
            name: "unicode-text-coercion",
            expression: Coerce(
                value: Variable(name: "value"),
                type: keyword("utxt", "Unicode text"),
            ),
        ),
        (
            name: "do-shell-script",
            expression: standardCommand("do shell script", "sysoexec"),
        ),
        (
            name: "quoted-form-specifier",
            expression: Specifier(
                kind: .property,
                object: keyword("strq", "quoted form"),
            ),
        ),
        (
            name: "posix-path-specifier",
            expression: Specifier(
                kind: .property,
                object: keyword("psxp", "POSIX path"),
            ),
        ),
        (name: "space", expression: keyword("spac", "space")),
        (name: "tab", expression: keyword("tab ", "tab")),
        (name: "linefeed", expression: keyword("lnfd", "linefeed")),
        (name: "return", expression: keyword("ret ", "return")),
    ]
    for test in tests {
        guard let fact = StringEnvironment().fact(of: test.expression) else {
            Issue.record("\(test.name): trusted text producer was not recognized")
            continue
        }
        #expect(!fact.constant, "\(test.name): dynamic producer was treated as constant")
    }
}

@Test func `named keyword prefers raw code`() throws {
    try #require(
        !Optional(Keyword(code: .four("bad!"), fallback: "text")).isKeyword(named: "text"),
        "conflicting fallback overrode raw code",
    )
    try #require(Optional(Keyword(fallback: "text")).isKeyword(named: "text"), "fallback-only keyword was not recognized")
}

/**
 Builds a command call sent to the script itself.

 At most eight bytes of `code` are used, and missing bytes are zero.
 */
func standardCommand(_ name: String, _ code: String, _ arguments: any Argument...) -> CommandCall {
    CommandCall(code: EventCode(bytes: Array(code.utf8)), name: name, arguments: arguments)
}

/** Each case is one block below. */
@Test func `string contracts`() throws {
    do {
        // Subtest "preserves-general-list".
        let list = List(elements: [
            StringLiteral(value: "killall"),
            StringLiteral(value: "-9"),
            Variable(name: "process_name"),
        ])
        #expect(list.foldedText === list, "general list was rewritten")
    }
    do {
        // Subtest "empty-list".
        let list = List()
        #expect(list.foldedText === list, "empty list was rewritten")
    }
    do {
        // Subtest "single-character-unicode-list".
        let list = List(elements: [
            StringLiteral(value: "a"),
            StringLiteral(value: "\""),
            StringLiteral(value: "é"),
        ])
        let got = try #require(list.foldedText as? List)
        #expect(got.elements.count == 3)
    }
    do {
        // Subtest "numbers-remain-numeric".
        let number = NumberLiteral(integer: 85)
        #expect(number.foldedText === number, "number was rewritten")
    }
    do {
        // Subtest "ascii-character-command".
        let call = standardCommand(
            "sysontoc",
            "sysontoc",
            DirectArgument(value: NumberLiteral(integer: 85)),
        )
        let got = call.foldedText as? StringLiteral
        #expect(got?.value == "U", "ASCII character")
    }
    do {
        // Subtest "empty-concatenation".
        let expression = Binary(
            op: .concatenate, left: StringLiteral(), right: StringLiteral(),
        )
        let got = expression.foldedText as? StringLiteral
        #expect(got?.value == "", "empty concatenation")
    }
}

// MARK: - A chain is read once, part by part

/** A short text for an expression, with every `&` in parentheses, so that a test can compare shapes. */
private func shape(_ expression: any Expr?) -> String {
    switch expression {
    case let node as StringLiteral:
        "\"\(node.value)\""
    case let node as Variable:
        node.name
    case let node as Binary:
        "(\(shape(node.left)) \(node.op == .concatenate ? "&" : "?") \(shape(node.right)))"
    case let node as Coerce:
        "\(shape(node.value)) as text"
    case let node as HandlerCall:
        "\(node.name)(\(node.arguments.map(shape).joined(separator: ", ")))"
    default:
        "?"
    }
}

/** The shape of `expression` after the pass, in a handler that starts with `set s to "S"`. */
private func folded(_ expression: any Expr) -> String {
    let last = Return(value: expression)
    let script = Script(handlers: [Handler(name: "t", body: [SetStmt(target: Variable(name: "s"), value: StringLiteral(value: "S")), last])])
    _ = Strings().rewrite(script)
    return shape(last.value)
}

private func text(_ value: String) -> StringLiteral {
    StringLiteral(value: value)
}

/** `x as text`: text, with a value that is not known. */
private func someText() -> Coerce {
    Coerce(value: Variable(name: "x"), type: Keyword(fallback: "text"))
}

/**
 Each part of a chain whose operands are all text is folded, and a part
 with a value of unknown type keeps its shape:

 ```
 "a" & "b" & l & "c" & "d"      →  "ab" & l & "c" & "d"
 l & ("c" & "d")                →  l & "cd"
 ```

 With `l` a list, `l & "c" & "d"` adds two items: it is not `l & "cd"`.
 */
@Test func `a chain is folded part by part`() {
    let list = Variable(name: "l")
    #expect(folded(concatenate(text("a"), text("b"), list, text("c"), text("d"))) == #"((("ab" & l) & "c") & "d")"#)
    #expect(folded(concatenate(list, concatenate(text("c"), text("d")))) == #"(l & "cd")"#)
    #expect(folded(concatenate(list, concatenate(text("c"), concatenate(Variable(name: "s"), someText())))) == #"(l & ("cS" & x as text))"#)
    // Text of unknown value stays between the literals around it.
    #expect(folded(concatenate(text("a"), someText(), text("b"), text("c"))) == #"(("a" & x as text) & "bc")"#)
    #expect(folded(concatenate(text("a"), concatenate(someText(), concatenate(text("b"), text("c"))))) == #"(("a" & x as text) & "bc")"#)
    // A variable with a known text is replaced inside a folded part only.
    #expect(folded(concatenate(Variable(name: "s"), list)) == "(s & l)")
    #expect(folded(concatenate(list, Variable(name: "s"))) == "(l & s)")
    #expect(folded(concatenate(text("a"), Variable(name: "s"), list)) == #"("aS" & l)"#)
    #expect(folded(concatenate(Variable(name: "s"), Variable(name: "s"))) == #""SS""#)
    // The parts of an operand are rewritten, whatever the chain around it becomes.
    let call = HandlerCall(name: "f", arguments: [concatenate(text("a"), text("b"))])
    #expect(folded(concatenate(list, call, text("c"))) == #"((l & f("ab")) & "c")"#)
    #expect(folded(concatenate(list, concatenate(call, concatenate(list, concatenate(text("c"), text("d")))))) == #"(l & (f("ab") & (l & "cd")))"#)
}

/**
 A chain of 20,000 operands, on a thread with a large stack as the tool
 uses. The chain was read again at each `&`: 2,000 operands took 14
 seconds, and the time grew with the cube of the length. It is read once
 now, in a few milliseconds.
 */
@Test func `a long chain is folded in one reading`() {
    final class Found: @unchecked Sendable {
        var text = ""
    }
    let found = Found()
    let thread = Thread {
        var operands: [any Expr] = []
        for _ in 0 ..< 5000 {
            operands += [text("a"), text("b"), someText(), text("c")] as [any Expr]
        }
        // "ab" & x as text & "cab" & x as text & … & "c"
        let last = Return(value: concatenate(operands))
        _ = Strings().rewrite(Script(handlers: [Handler(body: [last])]))
        var expression = last.value
        var count = 0
        while let node = expression as? Binary {
            count += 1
            expression = node.left
        }
        found.text = "\(count) operators, first \(shape(expression))"
    }
    thread.stackSize = 256 << 20
    thread.start()
    while !thread.isFinished {
        Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(found.text == #"10000 operators, first "ab""#)
}
