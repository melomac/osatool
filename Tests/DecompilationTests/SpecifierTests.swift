import AST
import Bytecode
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Terminology
import Testing

@Test func `every prop canonicalizes to properties`() throws {
    let s = try contractState()
    s.stack = [
        Variable(name: "documentValue"),
        Keyword(code: .four("prop")),
    ]
    s.makeSpecifier(.every)
    let specifier = try #require(s.pop() as? Specifier, "properties alias")
    let keyword = specifier.object as? Keyword
    try #require(
        keyword != nil && specifier.kind == .property && keyword?.fallback == "properties",
        "properties alias",
    )
}

@Test func `specifier stack contracts`() throws {
    let f = try contractState()
    let container = Variable(name: "values")
    let object = Keyword(fallback: "item")

    f.stack = [container, object, NumberLiteral(integer: 2)]
    f.makeSpecifier(.index)
    let index = try #require(f.pop() as? Specifier)
    let indexFrom = try #require(index.from as? NumberLiteral)
    try #require(
        index.kind == .index && index.container === container && indexFrom.integer == 2,
        "index specifier",
    )

    f.stack = [container, object, NumberLiteral(integer: 7), Keyword(code: .four("ID  "))]
    f.makeSpecifier(.key)
    let key = try #require(f.pop() as? Specifier)
    try #require(key.kind == .key && key.keyName == "id", "key specifier")

    f.stack = [container, object, NumberLiteral(integer: 1), NumberLiteral(integer: 3)]
    f.makeSpecifier(.range)
    let ranged = try #require(f.pop() as? Specifier)
    let rangedFrom = try #require(ranged.from as? NumberLiteral)
    let rangedTo = try #require(ranged.to as? NumberLiteral)
    try #require(
        ranged.kind == .range && rangedFrom.integer == 1 && rangedTo.integer == 3,
        "range specifier",
    )

    let predicate = BooleanLiteral(value: true)
    f.stack = [object, predicate]
    f.makeSpecifier(.whose)
    let whose = try #require(f.pop() as? Whose)
    try #require(whose.object === object && whose.predicate === predicate, "whose")
}

@Test func `comparison contracts`() throws {
    let s = try contractState()
    let left = NumberLiteral(integer: 1)
    let right = NumberLiteral(integer: 2)
    let cases: [(UInt8, BinaryKind)] = [
        (0, .equal), (1, .notEqual), (2, .greater), (3, .greaterEqual),
        (4, .less), (5, .lessEqual), (6, .startsWith), (7, .endsWith), (8, .contains),
    ]
    for (opcode, want) in cases {
        s.stack = [left, right]
        s.makeComparison(opcode)
        let got = try #require(s.pop() as? Binary).op
        #expect(got == want, "comparison \(opcode)")
    }
    s.stack = [left]
    s.makeComparison(11)
    let got = try #require(s.pop() as? Unary).op
    #expect(got == .not, "not comparison")
}

/** The form of a reference by key is a constant: `id`, or `named`. */
@Test func `key forms`() throws {
    func keyName(_ form: Keyword) throws -> String {
        let s = try contractState()
        s.stack = [Variable(name: "c"), Keyword(code: .four("cobj")), StringLiteral(value: "x"), form]
        s.makeSpecifier(.key)
        return try #require(s.stack.last as? Specifier).keyName
    }
    #expect(try keyName(Keyword(code: .eight("kfrmID  "))) == "id")
    #expect(try keyName(Keyword(code: .eight("kfrmname"))) == "named")
    #expect(try keyName(Keyword(code: .four("name"))) == "named")
    #expect(try keyName(Keyword(code: .eight("zzzzname"))) == "id")
}

/**
 `{name, size} of x`: the compiler works `x` out once, so the items of
 the list have the very same object as their container.
 */
@Test func `one container for the items of a list`() throws {
    let s = try contractState()
    let x = Variable(name: "x")
    func property(_ name: String, of container: any Expr) -> Specifier {
        Specifier(kind: .property, object: Keyword(fallback: name), container: container)
    }
    let shared = try #require(s.sharedContainer([property("name", of: x), property("size", of: x)]) as? Specifier)
    #expect(shared.container === x)
    #expect(((shared.object as? List)?.elements.first as? Specifier)?.container == nil)
    #expect((shared.object as? List)?.elements.count == 2)

    // Two references written one by one have two containers.
    #expect(s.sharedContainer([property("name", of: x), property("size", of: Variable(name: "x"))]) == nil)
    // One item alone shares nothing, unless its container was seen being removed.
    #expect(s.sharedContainer([property("name", of: x)]) == nil)
    s.stack = [property("name", of: x), x]
    s.discard()
    #expect(s.sharedContainer(s.stack) != nil)
    #expect(s.sharedContainer([NumberLiteral(integer: 1), property("name", of: x)]) == nil)
}
