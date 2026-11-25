@testable import AST
import Extensions
import Terminology
import Testing

/** Returns the names of the variables among some expressions. */
private func names(_ expressions: [any Expr]) -> [String] {
    expressions.compactMap { ($0 as? Variable)?.name }
}

private func variable(_ name: String) -> Variable {
    Variable(name: name)
}

/** Each kind of expression gives its children in the order of the source. */
@Test func `children of expressions`() {
    #expect(variable("x").children.isEmpty)
    #expect(StringLiteral(value: "x").children.isEmpty)
    #expect(names(List(elements: [variable("a"), nil, variable("b")]).children) == ["a", "b"])
    #expect(names(Record(fields: [RecordField(label: variable("k"), value: variable("v"))]).children) == ["k", "v"])
    #expect(names(Unary(op: .not, value: variable("a")).children) == ["a"])
    #expect(names(Binary(op: .add, left: variable("l"), right: variable("r")).children) == ["l", "r"])
    #expect(names(Coerce(value: variable("v"), type: variable("t")).children) == ["v", "t"])
    #expect(names(Reference(value: variable("v")).children) == ["v"])
    #expect(names(HandlerCall(name: "f", target: variable("t"), arguments: [variable("a"), variable("b")]).children) == ["t", "a", "b"])
    #expect(names(ContinueExpr(call: variable("c")).children) == ["c"])
    #expect(names(Whose(object: variable("o"), predicate: variable("p")).children) == ["o", "p"])

    let specifier = Specifier(kind: .range, object: variable("o"), container: variable("c"), from: variable("f"), to: variable("t"))
    #expect(names(specifier.children) == ["o", "c", "f", "t"])

    let command = CommandCall(
        name: "do", target: variable("t"),
        arguments: [DirectArgument(value: variable("d")), FlagArgument(name: "quiet", enabled: true), NamedArgument(name: "with", value: variable("n"))],
    )
    #expect(names(command.children) == ["t", "d", "n"])

    let labeled = LabeledCall(name: "f", direct: variable("d"), arguments: [LabeledArgument(label: .word("size"), value: variable("s"))])
    #expect(names(labeled.children) == ["d", "s"])

    // A script object gives the values of its properties.
    let object = ScriptObject(name: "box", properties: [Property(name: "p", value: variable("v"))])
    #expect(names(object.children) == ["v"])
}

@Test func `rewriting the children of an expression`() {
    let sum = Binary(op: .add, left: variable("a"), right: variable("b"))
    sum.rewriteChildren { child in
        (child as? Variable).map { Variable(name: $0.name.uppercased()) }
    }
    #expect(names(sum.children) == ["A", "B"])
}

/** A statement gives its own expressions, and the lists of statements inside it. */
@Test func `expressions and bodies of statements`() {
    func expressions(_ statement: any Stmt) -> [String] {
        var found: [any Expr] = []
        statement.rewriteExpressions { expression in
            if let expression {
                found.append(expression)
            }
            return expression
        }
        return names(found)
    }
    #expect(expressions(SetStmt(target: variable("t"), value: variable("v"))) == ["t", "v"])
    #expect(expressions(Copy(source: variable("s"), target: variable("t"))) == ["s", "t"])
    #expect(expressions(Expression(value: variable("v"))) == ["v"])
    #expect(expressions(Return(value: variable("v"), explicit: true)) == ["v"])
    #expect(expressions(Continue(call: variable("c"))) == ["c"])
    #expect(expressions(Tell(target: variable("t"))) == ["t"])
    #expect(expressions(Timeout(seconds: variable("s"))) == ["s"])
    #expect(expressions(If(condition: variable("c"))) == ["c"])
    #expect(expressions(Repeat(kind: .range, from: variable("f"), to: variable("t"), by: variable("b"))) == ["f", "t", "b"])
    #expect(expressions(ExitRepeat()).isEmpty)
    #expect(expressions(Try()).isEmpty)

    let exit = ExitRepeat()
    #expect(ExitRepeat().bodies.isEmpty)
    #expect(SetStmt().bodies.isEmpty)
    #expect(If(then: [exit], else: [exit, exit]).bodies.map(\.count) == [1, 2])
    #expect(Try(body: [exit], errorBody: []).bodies.map(\.count) == [1, 0])
    for statement: any Stmt in [Repeat(body: [exit]), Tell(body: [exit]), Considering(body: [exit]), Timeout(body: [exit]), Transaction(body: [exit])] {
        #expect(statement.bodies.map(\.count) == [1], "\(statement.nodeName)")
    }
}

/**
 The walk reaches every expression: inside each kind of block, inside a
 `continue`, and inside a script object in an expression. A child is
 visited before the expression around it.
 */
@Test func `every expression of some statements is visited`() {
    let inner = ScriptObject(
        name: "inner",
        properties: [Property(name: "p", value: variable("innerProperty"))],
        handlers: [Handler(name: "h", body: [Return(value: variable("innerHandler"), explicit: true)])],
    )
    let object = ScriptObject(
        name: "outer",
        properties: [Property(name: "p", value: variable("property"))],
        objects: [inner],
        handlers: [Handler(name: "h", body: [Return(value: variable("handler"), explicit: true)])],
    )
    let statements: [any Stmt] = [
        If(condition: variable("condition"), then: [Expression(value: variable("then"))], else: [Expression(value: variable("else"))]),
        Try(body: [Expression(value: variable("try"))], errorBody: [Expression(value: variable("error"))]),
        Transaction(body: [Expression(value: variable("transaction"))]),
        Considering(body: [Expression(value: variable("considering"))]),
        Continue(call: HandlerCall(name: "f", arguments: [variable("continued")])),
        Expression(value: Binary(op: .add, left: variable("left"), right: object)),
    ]
    var visited: [String] = []
    statements.rewriteEveryExpression { expression in
        if let node = expression as? Variable {
            visited.append(node.name)
        } else if let expression {
            visited.append(expression.nodeName)
        }
        return expression
    }
    #expect(visited == [
        "condition", "then", "else", "try", "error", "transaction", "considering",
        "continued", "HandlerCall",
        "left", "property", "innerProperty", "innerHandler", "handler", "ScriptObject", "Binary",
    ])
}
