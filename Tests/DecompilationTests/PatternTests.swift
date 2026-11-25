import AST
import Bytecode
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Terminology
import Testing

/** Returns `item n of container`, as the compiler reads one part of a list. */
private func item(_ number: Int, of container: any Expr) -> Specifier {
    Specifier(kind: .index, object: Keyword(code: .four("cobj")), container: container, from: NumberLiteral(integer: Int64(number)))
}

/**
 Sets `name` from the top of the stack, then removes the top: the two
 instructions `PopVariable` and `Pop` that end one part of a pattern.
 */
private func store(_ name: String, in state: State) {
    state.pending = Variable(name: name)
    state.discard()
}

private func names(_ pattern: any Expr?) -> [String] {
    ((pattern as? List)?.elements ?? []).map { ($0 as? Variable)?.name ?? "{" + names($0).joined(separator: ", ") + "}" }
}

/**
 `set {a, {b, c}} to pair`: the value stays on the stack while each
 name takes its part, then it is stored as the result.
 */
@Test func `the parts of a pattern make one assignment`() throws {
    let s = try contractState()
    let pair = Variable(name: "pair")
    s.stack = [pair, item(1, of: pair)]
    store("a", in: s)
    let second = item(2, of: pair)
    s.stack += [second, item(1, of: second)]
    store("b", in: s)
    s.stack.append(item(2, of: second))
    store("c", in: s)
    // The `Pop` that removes `item 2 of pair`, with nothing to store.
    s.discard()
    #expect(s.stack.count == 1 && s.handler.body.isEmpty)
    s.storeResult()

    #expect(s.handler.body.count == 1)
    let statement = try #require(s.handler.body.first as? SetStmt)
    #expect(names(statement.target) == ["a", "{b, c}"])
    #expect(statement.value === pair)
    #expect(s.stack.isEmpty && s.patternParts.isEmpty)
}

/** With `Clone` before each store, the statement is `copy pair to {a, b}`. */
@Test func `the copied parts of a pattern make one copy`() throws {
    let s = try contractState()
    let pair = Variable(name: "pair")
    s.stack = [pair, CopyExpr(value: item(1, of: pair))]
    store("a", in: s)
    s.stack.append(CopyExpr(value: item(2, of: pair)))
    store("b", in: s)
    s.storeResult()
    let statement = try #require(s.handler.body.first as? Copy)
    #expect(names(statement.target) == ["a", "b"])
    #expect(statement.source === pair)
}

/**
 Parts that do not make a pattern are not lost: each one is written as
 a statement of its own. Here item 1 has no name.
 */
@Test func `parts that are not a pattern are written one by one`() throws {
    let s = try contractState()
    let pair = Variable(name: "pair")
    s.stack = [pair, item(2, of: pair)]
    store("b", in: s)
    s.storeResult()
    #expect(s.handler.body.count == 2)
    let first = try #require(s.handler.body.first as? SetStmt)
    #expect((first.target as? Variable)?.name == "b")
    #expect((first.value as? Specifier)?.container === pair)
    #expect((s.handler.body.last as? AST.Expression)?.value === pair)
}

/** A `Pop` after a store of something that is not a part works as before. */
@Test func `a store that is not a part of the value below is not a pattern`() throws {
    let s = try contractState()
    s.stack = [Variable(name: "pair"), item(1, of: Variable(name: "other"))]
    store("a", in: s)
    #expect(s.patternParts.isEmpty)
    #expect(s.stack.count == 1)
    #expect((s.pending as? Variable)?.name == "a")
}
