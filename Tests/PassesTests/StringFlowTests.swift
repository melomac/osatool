import AST
import Extensions
@testable import Passes
import Terminology
import Testing

/**
 A name inside a pattern parameter hides a property with the same name,
 like a plain parameter does.
 */
@Test func `a pattern parameter hides a property`() {
    let pattern = List(elements: [Variable(name: "first"), Variable(name: "second")])
    let handler = Handler(name: "pat", parameters: [Parameter(pattern: pattern), Parameter(name: "third")])
    let level = StringLevel(names: ["first", "third", "other"], shared: ["second", "global"], trackLocals: true)
    #expect(handler.blockedVariables(level) == ["other"])
    // The shared globals count in the run handler of the script only.
    let run = Handler(parameters: [Parameter(name: "third")], body: [Declaration(names: ["Global"], global: false)], isRunHandler: true)
    #expect(run.blockedVariables(level) == ["first", "other", "second"])
}

@Test func `strings propagates immutable text assignments`() throws {
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "first"),
            value: StringLiteral(value: "value"),
        ),
        SetStmt(
            target: Variable(name: "second"),
            value: Variable(name: "first"),
        ),
        SetStmt(
            target: Variable(name: "result"),
            value: concatenate(
                Variable(name: "second"),
                StringLiteral(value: "-suffix"),
            ),
        ),
        SetStmt(
            target: Variable(name: "first_result"),
            value: concatenate(
                Variable(name: "first"),
                StringLiteral(value: "-suffix"),
            ),
        ),
    ])])

    _ = Strings().rewrite(script)

    let value = try #require(script.handlers[0].body[2] as? SetStmt).value
    try #require((value as? StringLiteral)?.value == "value-suffix", "assigned text")
    let first = try #require(script.handlers[0].body[3] as? SetStmt).value
    try #require((first as? StringLiteral)?.value == "value-suffix", "source text")
}

@Test func `strings merges only agreed branch values`() throws {
    func makeScript(_ left: String, _ right: String) -> Script {
        Script(handlers: [Handler(body: [
            If(
                condition: BooleanLiteral(value: true),
                then: [SetStmt(
                    target: Variable(name: "part"),
                    value: StringLiteral(value: left),
                )],
                else: [SetStmt(
                    target: Variable(name: "part"),
                    value: StringLiteral(value: right),
                )],
            ),
            SetStmt(
                target: Variable(name: "result"),
                value: concatenate(
                    StringLiteral(value: "a"),
                    Variable(name: "part"),
                    StringLiteral(value: "b"),
                ),
            ),
        ])])
    }

    let agreed = makeScript("x", "x")
    _ = Strings().rewrite(agreed)
    let agreedValue = try #require(agreed.handlers[0].body[1] as? SetStmt).value
    let got = try #require(agreedValue as? StringLiteral).value
    try #require(got == "axb", "agreed branches")

    let disagreed = makeScript("x", "y")
    _ = Strings().rewrite(disagreed)
    let value = try #require(disagreed.handlers[0].body[1] as? SetStmt).value
    try #require(value is Binary, "disagreed branches were propagated")
}

@Test func `strings does not propagate loop mutations`() throws {
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "value"),
            value: StringLiteral(),
        ),
        Repeat(
            kind: .forever,
            body: [SetStmt(
                target: Variable(name: "value"),
                value: concatenate(
                    Variable(name: "value"),
                    StringLiteral(value: "x"),
                ),
            )],
        ),
    ])])

    _ = Strings().rewrite(script)

    let loop = try #require(script.handlers[0].body[1] as? Repeat)
    let value = try #require(loop.body[0] as? SetStmt).value
    let binary = try #require(value as? Binary, "loop-carried value was propagated")
    try #require(binary.left is Variable, "loop-carried left operand")
}

@Test func `strings does not propagate partial try assignments`() throws {
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "value"),
            value: StringLiteral(value: "before"),
        ),
        Try(
            body: [SetStmt(
                target: Variable(name: "value"),
                value: StringLiteral(value: "during"),
            )],
            errorBody: [SetStmt(
                target: Variable(name: "result"),
                value: concatenate(
                    Variable(name: "value"),
                    StringLiteral(value: "-error"),
                ),
            )],
        ),
    ])])

    _ = Strings().rewrite(script)

    let handler = try #require(script.handlers[0].body[1] as? Try)
    let value = try #require(handler.errorBody[0] as? SetStmt).value
    let binary = try #require(value as? Binary, "partial try value was propagated")
    try #require(binary.left is Variable, "partial try left operand")
}

@Test func `strings does not propagate shared variables`() {
    let tests: [(name: String, properties: [Property], prefix: [any Stmt])] = [
        (
            name: "property",
            properties: [Property(name: "shared", value: StringLiteral(value: "initial"))],
            prefix: [],
        ),
        (
            name: "explicit-global",
            properties: [],
            prefix: [Declaration(
                names: ["shared"],
                global: true,
            )],
        ),
    ]
    for test in tests {
        var body: [any Stmt] = test.prefix
        body.append(contentsOf: [
            SetStmt(
                target: Variable(name: "shared"),
                value: StringLiteral(value: "local-looking"),
            ),
            SetStmt(
                target: Variable(name: "result"),
                value: concatenate(
                    Variable(name: "shared"),
                    StringLiteral(value: "-suffix"),
                ),
            ),
        ] as [any Stmt])
        let script = Script(
            properties: test.properties,
            handlers: [Handler(body: body)],
        )

        _ = Strings().rewrite(script)

        let got = (script.handlers[0].body[body.count - 1] as? SetStmt)?.value
        #expect(got is Binary, "\(test.name): shared variable was propagated")
    }
}

@Test func `strings does not propagate repeat condition mutations`() throws {
    let loop = Repeat(
        kind: .while,
        condition: concatenate(
            Variable(name: "value"),
            StringLiteral(value: "-condition"),
        ),
        body: [SetStmt(
            target: Variable(name: "value"),
            value: StringLiteral(value: "changed"),
        )],
    )
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "value"),
            value: StringLiteral(value: "initial"),
        ),
        loop,
    ])])

    _ = Strings().rewrite(script)

    try #require(loop.condition is Binary, "repeat condition mutation was propagated")
}

@Test func `strings respects error bindings`() throws {
    let handler = Try(
        errorName: "problem",
        errorBody: [SetStmt(
            target: Variable(name: "result"),
            value: concatenate(
                Variable(name: "problem"),
                StringLiteral(value: "-suffix"),
            ),
        )],
    )
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "problem"),
            value: StringLiteral(value: "outer"),
        ),
        handler,
    ])])

    _ = Strings().rewrite(script)

    let value = try #require(handler.errorBody[0] as? SetStmt).value
    try #require(value is Binary, "error binding was propagated")
}

@Test func `strings isolates nested script scopes`() throws {
    let object = ScriptObject(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "result"),
            value: concatenate(
                Variable(name: "fragment"),
                StringLiteral(value: "-inner"),
            ),
        ),
    ])])
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "fragment"),
            value: StringLiteral(value: "outer"),
        ),
        SetStmt(
            target: Variable(name: "object"),
            value: object,
        ),
        SetStmt(
            target: Variable(name: "fragment"),
            value: StringLiteral(value: "after"),
        ),
        SetStmt(
            target: Variable(name: "result"),
            value: concatenate(
                Variable(name: "fragment"),
                StringLiteral(value: "-outer"),
            ),
        ),
    ])])

    _ = Strings().rewrite(script)

    let value = try #require(object.handlers[0].body[0] as? SetStmt).value
    try #require(value is Binary, "outer value leaked into nested script")
    let outer = try #require(script.handlers[0].body[3] as? SetStmt).value
    try #require(outer is Binary, "handler containing nested script propagated locals")
}

@Test func `strings invalidates escaped references`() throws {
    let script = Script(handlers: [Handler(body: [
        SetStmt(
            target: Variable(name: "reference"),
            value: Reference(
                value: Variable(name: "fragment"),
            ),
        ),
        SetStmt(
            target: Variable(name: "fragment"),
            value: StringLiteral(value: "before"),
        ),
        SetStmt(
            target: Specifier(
                kind: .property,
                object: Keyword(fallback: "contents"),
                container: Variable(name: "reference"),
            ),
            value: StringLiteral(value: "after"),
        ),
        SetStmt(
            target: Variable(name: "result"),
            value: concatenate(
                Variable(name: "fragment"),
                StringLiteral(value: "-after"),
            ),
        ),
    ])])

    _ = Strings().rewrite(script)

    let value = try #require(script.handlers[0].body[3] as? SetStmt).value
    try #require(value is Binary, "persistent reference was propagated through")
}

/**
 A reference to a local, or a script object, lets the local change
 without a visible assignment. It is found in every kind of block, also
 inside a transaction and a `continue`.
 */
@Test func `a local escape is found in every block`() {
    let reference = Reference(value: Variable(name: "x"))
    #expect(!([Expression(value: Variable(name: "x"))] as [any Stmt]).letsLocalsEscape)
    #expect(([Expression(value: reference)] as [any Stmt]).letsLocalsEscape)
    #expect(([Transaction(body: [Expression(value: reference)])] as [any Stmt]).letsLocalsEscape)
    #expect(([Continue(call: HandlerCall(name: "f", arguments: [reference]))] as [any Stmt]).letsLocalsEscape)
    #expect(([Try(body: [], errorBody: [Expression(value: ScriptObject(name: "s"))])] as [any Stmt]).letsLocalsEscape)
}

// MARK: - Targets that are not a plain variable

/** `set a to "x"`, one more statement, then `return a & "y"`: true when the pass joins the text. */
private func joinsAfter(_ statement: any Stmt, isRunHandler: Bool = false, members: [Member] = []) -> Bool {
    let last = Return(value: concatenate(Variable(name: "a"), StringLiteral(value: "y")))
    let body: [any Stmt] = [SetStmt(target: Variable(name: "a"), value: StringLiteral(value: "x")), statement, last]
    let script = Script()
    script.members = members + [.handler(Handler(name: "t", body: body, isRunHandler: isRunHandler))]
    _ = Strings().rewrite(script)
    return (last.value as? StringLiteral)?.value == "xy"
}

/**
 A pattern gives a part of the value to each of its names:

 ```
 set a to "x"
 set {a, b} to r        a is item 1 of r now
 return a & "y"         not "xy"
 ```

 The pass read the target as one variable, found none, and kept what it
 knew about `a`.
 */
@Test func `a pattern takes away what was known about its names`() {
    let source = Variable(name: "r")
    let pair = List(elements: [Variable(name: "a"), Variable(name: "b")])
    #expect(!joinsAfter(SetStmt(target: pair, value: source)))
    #expect(!joinsAfter(Copy(source: source, target: pair)))
    let nested = List(elements: [Variable(name: "b"), List(elements: [Variable(name: "A"), Variable(name: "c")])])
    #expect(!joinsAfter(SetStmt(target: nested, value: source)))
    let record = Record(fields: [RecordField(label: Variable(name: "p"), value: Variable(name: "a"))])
    #expect(!joinsAfter(SetStmt(target: record, value: source)))
    // A property of an object named like the variable: it is forgotten too.
    let property = Specifier(kind: .property, object: Variable(name: "a"), container: Variable(name: "x"))
    #expect(!joinsAfter(SetStmt(target: property, value: source)))
    // A pattern with other names, and a part of another variable, change nothing.
    #expect(joinsAfter(SetStmt(target: List(elements: [Variable(name: "b"), Variable(name: "c")]), value: source)))
    #expect(joinsAfter(SetStmt(target: Specifier(kind: .index, object: NumberLiteral(integer: 1), container: Variable(name: "b")), value: source)))
}

// MARK: - Names that more than one handler can reach

/**
 A handler of a script object can set a property of the script around
 it, and so can the handler it calls:

 ```
 property p : "a"
 script s
     on f()
         set p to "x"
         g()               sets p to 5
         return p & "y"    not "xy"
     end f
 end script
 ```

 Only the properties of the script object itself were left out.
 */
@Test func `a name of a script around is not tracked`() {
    func joins(_ name: String, in script: Script, _ handler: Handler) -> Bool {
        let last = Return(value: concatenate(Variable(name: name), StringLiteral(value: "y")))
        handler.body = [
            SetStmt(target: Variable(name: name), value: StringLiteral(value: "x")),
            Expression(value: HandlerCall(name: "g")),
            last,
        ]
        _ = Strings().rewrite(script)
        return (last.value as? StringLiteral)?.value == "xy"
    }
    let inner = Handler(name: "f")
    let deep = ScriptObject(name: "deep", handlers: [inner])
    let object = ScriptObject(name: "s", properties: [Property(name: "q")], objects: [deep])
    let script = Script(properties: [Property(name: "P")], objects: [object], handlers: [Handler(name: "helper")])
    // A property two levels up, one level up, and the name of a script object.
    #expect(!joins("p", in: script, inner))
    #expect(!joins("q", in: script, inner))
    #expect(!joins("S", in: script, inner))
    #expect(!joins("deep", in: script, inner))
    #expect(joins("other", in: script, inner))
    // A parameter hides the property.
    inner.parameters = [Parameter(name: "p")]
    #expect(joins("p", in: script, inner))
}

/**
 In the run handler of the script a plain name is a global, and another
 handler can reach it:

 ```
 set a to "x"            on f()
 f()                         global a
 return a & "y"              set a to 5
                         end f
 ```
 */
@Test func `a global that other code can reach is not tracked in the run handler`() {
    let call = Expression(value: HandlerCall(name: "f"))
    let global = Declaration(names: ["A"], global: true)
    let setFive = SetStmt(target: Variable(name: "a"), value: NumberLiteral(integer: 5))
    let ofMe = Specifier(kind: .property, object: Variable(name: "a"), container: Me())
    func handler(_ body: [any Stmt]) -> Member {
        .handler(Handler(name: "f", body: body))
    }

    // A `global` line in another handler, at any depth of its blocks.
    #expect(!joinsAfter(call, isRunHandler: true, members: [handler([global, setFive])]))
    #expect(!joinsAfter(call, isRunHandler: true, members: [handler([Transaction(body: [Try(body: [global])])])]))
    // In a handler of a script object, and of a script object made in a handler.
    let object = ScriptObject(name: "s", handlers: [Handler(name: "g", body: [global, setFive])])
    #expect(!joinsAfter(call, isRunHandler: true, members: [.object(object)]))
    #expect(!joinsAfter(call, isRunHandler: true, members: [handler([Expression(value: Unary(op: .not, value: object))])]))
    #expect(!joinsAfter(call, isRunHandler: true, members: [.property(Property(name: "p", value: List(elements: [object])))]))
    // The `global` line of the script itself.
    #expect(!joinsAfter(call, isRunHandler: true, members: [.globals(global)]))
    // `set my a to 5`, `a of x`, `a reference to a`: the global as a property of an object.
    #expect(!joinsAfter(call, isRunHandler: true, members: [handler([SetStmt(target: ofMe, value: NumberLiteral(integer: 5))])]))
    #expect(!joinsAfter(call, isRunHandler: true, members: [handler([Return(value: Reference(value: ofMe))])]))
    let ofX = Specifier(kind: .property, object: Variable(name: "a"), container: Variable(name: "x"))
    #expect(!joinsAfter(call, isRunHandler: true, members: [handler([Return(value: Binary(op: .add, left: ofX, right: NumberLiteral(integer: 1)))])]))

    // Another handler with a local `a`, or with another global: the text is joined.
    #expect(joinsAfter(call, isRunHandler: true, members: [handler([setFive])]))
    #expect(joinsAfter(call, isRunHandler: true, members: [handler([Declaration(names: ["z"], global: true)])]))
    // `local a` in the run handler: the name is not the global.
    let last = Return(value: concatenate(Variable(name: "a"), StringLiteral(value: "y")))
    let run = Handler(body: [
        Declaration(names: ["a"], global: false),
        SetStmt(target: Variable(name: "a"), value: StringLiteral(value: "x")),
        call,
        last,
    ], isRunHandler: true)
    let script = Script()
    script.members = [handler([global, setFive]), .handler(run)]
    _ = Strings().rewrite(script)
    #expect((last.value as? StringLiteral)?.value == "xy")
    // In a plain handler, `a` is a local: the `global a` of another handler is another variable.
    #expect(joinsAfter(call, members: [handler([global, setFive])]))
}

/**
 The run handler of a script object has locals, where the run handler
 of the script has globals: the compiler was asked. So the `global a` of
 another handler is another variable there.
 */
@Test func `the run handler of a script object has locals`() {
    let last = Return(value: concatenate(Variable(name: "a"), StringLiteral(value: "y")))
    let run = Handler(body: [
        SetStmt(target: Variable(name: "a"), value: StringLiteral(value: "x")),
        Expression(value: HandlerCall(name: "f")),
        last,
    ], isRunHandler: true, isImplicit: true)
    let other = Handler(name: "f", body: [Declaration(names: ["a"], global: true)])
    let script = Script(objects: [ScriptObject(name: "s", handlers: [run])], handlers: [other])
    _ = Strings().rewrite(script)
    #expect((last.value as? StringLiteral)?.value == "xy")
}
