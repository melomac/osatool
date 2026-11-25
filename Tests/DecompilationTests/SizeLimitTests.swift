import AST
import Bytecode
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Terminology
import Testing

/** True when a statement has the mark that stands for a large part printed before. */
private func hasMark(_ statement: any Stmt) -> Bool {
    var found = false
    ([statement] as [any Stmt]).rewriteEveryExpression { expression in
        if (expression as? Keyword)?.fallback == printedAboveMark {
            found = true
        }
        return expression
    }
    return found
}

/** The size of an expression is the number of nodes it prints: a node used twice counts twice. */
@Test func `expression sizes`() throws {
    let s = try contractState()
    let x = Variable(name: "x")
    #expect(s.size(of: x) == 1)
    let sum = Binary(op: .add, left: x, right: x)
    #expect(s.size(of: sum) == 3)
    let twice = Binary(op: .add, left: sum, right: sum)
    #expect(s.size(of: twice) == 7)
    #expect(s.size(of: List(elements: [twice, nil, StringLiteral(value: "a")])) == 9)
    // Every node that was measured is kept, with its size.
    #expect(s.sizes.count == 5)
}

/**
 `Dup` and `Add`, many times: the expression doubles at each step. It
 is replaced when it is much larger than the number of nodes that exist.
 */
@Test func `an expression that doubles is replaced`() throws {
    let s = try contractState()
    s.push(Variable(name: "x"))
    for offset in 0 ..< 40 {
        try s.instruction(instruction(91, "Dup", 2 * offset))
        try s.instruction(instruction(30, "Add", 2 * offset + 1))
    }
    #expect(s.stack.count == 1)
    // Without the limit, the expression would print 2^41 - 1 nodes.
    #expect(s.size(of: s.stack[0]) < 1 << 20)
    #expect(s.reportedTooLarge)
    #expect(s.decompiler.diagnostics.count == 1)
    #expect(s.decompiler.diagnostics.first?.function == 2)

    func holdsMarker(_ node: any Expr) -> Bool {
        (node as? Keyword)?.fallback == "«expression too large»" || node.children.contains { holdsMarker($0) }
    }
    #expect(holdsMarker(s.stack[0]))
}

/** A large expression of real code is not touched: each node is used once. */
@Test func `a large expression that does not repeat is kept`() throws {
    let s = try contractState()
    // A list of 5000 different items, each one a sum.
    for index in 0 ..< 5000 {
        s.push(Variable(name: "x\(index)"))
        s.push(NumberLiteral(integer: Int64(index)))
        try s.instruction(instruction(30, "Add", index))
    }
    s.push(NumberLiteral(integer: 5000))
    try s.instruction(instruction(13, "MakeList", 5000))
    #expect(s.size(of: s.stack[0]) == 15001)
    #expect((s.stack[0] as? List)?.elements.count == 5000)
    #expect(!s.reportedTooLarge)
    #expect(s.decompiler.diagnostics.isEmpty)
}

/**
 One expression used by many statements: `Dup`, then `StoreResult`,
 again and again. The handler stops printing the statements when their
 sum is much larger than the number of nodes that exist.
 */
@Test func `statements that repeat one large expression are left out`() throws {
    let s = try contractState()
    // A list of 5000 different items: a large expression of real code.
    let big = List(elements: (0 ..< 5000).map { Variable(name: "x\($0)") })
    s.push(big)
    for _ in 0 ..< 200 {
        s.push(Binary(op: .add, left: big, right: NumberLiteral(integer: 1)))
        s.flushExpression()
    }
    let comments = s.handler.body.filter(hasMark)
    #expect(!comments.isEmpty)
    #expect(comments.count < 200)
    #expect(s.handler.body.count == 200)
    #expect(s.reportedTooLarge)
}

// MARK: - Counts, depth and script objects that damaged code can ask for

/**
 `MakeList` takes its count from the stack, and damaged code can put any
 number there. Only what the stack has is taken: a count of 10^18 asked
 for that many places, and the program stopped.
 */
@Test func `a count larger than the stack takes what the stack has`() throws {
    for count in [NumberLiteral(real: 1e18, isReal: true), NumberLiteral(integer: .max), NumberLiteral(integer: 3)] {
        let state = try contractState()
        state.stack = [NumberLiteral(integer: 1), NumberLiteral(integer: 2), count]
        state.makeList()
        #expect(state.underflow)
        #expect((state.stack.last as? List)?.elements.count == 2)
        #expect(state.stack.count == 1)
    }
    // A count the stack can give, a negative one, and something that is not a number.
    let state = try contractState()
    state.stack = [NumberLiteral(integer: 1), NumberLiteral(integer: 2), NumberLiteral(integer: 2)]
    state.makeList()
    #expect(!state.underflow && (state.stack.last as? List)?.elements.count == 2)
    state.stack = [NumberLiteral(integer: 1), NumberLiteral(integer: -5)]
    state.makeList()
    #expect(!state.underflow && (state.stack.last as? List)?.elements.isEmpty == true && state.stack.count == 2)
    state.stack = [StringLiteral(value: "x")]
    state.makeList()
    #expect((state.stack.last as? List)?.elements.isEmpty == true)
}

/**
 One operation inside the other, as often as the code says: a megabyte
 of `Not` is a million levels, and what walks the tree calls itself for
 each one. Past the limit the expression is replaced.
 */
@Test func `an expression nested too deep is replaced`() throws {
    let state = try contractState()
    state.expressionDepthLimit = 100
    state.push(Variable(name: "x"))
    for _ in 0 ..< 99 {
        state.push(Unary(op: .not, value: state.pop()))
    }
    #expect(state.measure(state.stack[0]).depth == 100)
    #expect(state.stack[0] is Unary && state.decompiler.diagnostics.isEmpty)
    state.push(Unary(op: .not, value: state.pop()))
    #expect((state.stack[0] as? Keyword)?.fallback == "«expression too deep»")
    #expect(state.decompiler.diagnostics.count == 1)
    // The size and the depth of a node are worked out once.
    let sum = Binary(op: .add, left: Variable(name: "a"), right: Unary(op: .negate, value: Variable(name: "b")))
    #expect(state.measure(sum) == (4, 3) && state.size(of: sum) == 4)
}

/** One byte opens a block. Past the limit a block is not opened, and that is reported once. */
@Test func `blocks nested too deep are not opened`() throws {
    let state = try contractState()
    state.blockDepthLimit = 10
    for _ in 0 ..< 50 {
        state.open(Block(.timeout(Timeout())))
    }
    // The root block, and ten more.
    #expect(state.blocks.count == 11)
    #expect(state.decompiler.diagnostics.count == 1)
    #expect(state.decompiler.diagnostics.first?.message.contains("deeper than 10 levels") == true)
}

/** A function vector named `name`, with these literals and this code. */
private func initializer(_ name: String, literals: [Value], code: [UInt8]) -> Vector {
    Vector(type: 16, hasType: true, children: [
        .null, bytes(name), .null, .null, .null, .vector(Vector()), .vector(Vector(children: literals)), .bytes(code),
    ])
}

/**
 `DefineActor` rebuilds a script object from a literal, which is a
 function like any other. A damaged file can make that function hold
 itself: the rebuilding called itself without end.
 */
@Test func `a script object defined inside itself is printed empty`() throws {
    let terms = try Registry.default()
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions(terms: terms))
    // The code: `DefineActor` of literal 0, then `Return`.
    let own = initializer("s", literals: [], code: [0x4b, 0x00, 0x00, 0x0f])
    own.children[6] = .vector(Vector(children: [.vector(own)]))
    let object = decompiler.actor(own, "s", [])
    #expect(object.name == "s")
    // Once where it defines itself, and once more as one of its own handlers.
    #expect(decompiler.diagnostics.count { $0.message.contains("defined inside itself") } == 2)
    #expect(decompiler.actorsBeingRebuilt.isEmpty)
    // Take the loop apart, so that the vector is freed.
    own.children[6] = .null
}

/**
 Without a loop, each level can still hold the next one twice: twenty
 levels are a million script objects. No more than a fixed number are
 rebuilt, and no deeper than a fixed depth; that is reported once.
 */
@Test func `script objects in handlers are rebuilt up to a limit`() throws {
    let terms = try Registry.default()
    // Each one defines the next one twice: `DefineActor` 0, `DefineActor` 0, `Return`.
    var inner = initializer("leaf", literals: [], code: [0x0f])
    for level in 0 ..< 20 {
        inner = initializer("s\(level)", literals: [.vector(inner)], code: [0x4b, 0x00, 0x00, 0x4b, 0x00, 0x00, 0x0f])
    }
    let wide = Decompiler(script: CompiledScript(), options: RebuildOptions(terms: terms))
    _ = wide.actor(inner, "top", [])
    #expect(wide.actorBudget == 0)
    #expect(wide.diagnostics.count { $0.message.contains("script objects are defined in handlers") } == 1)

    // One inside the other, a hundred deep. A literal that is a function is
    // also read as a handler of the object, so each level is entered twice.
    var deep = initializer("leaf", literals: [], code: [0x0f])
    for level in 0 ..< 100 {
        deep = initializer("s\(level)", literals: [.vector(deep)], code: [0x4b, 0x00, 0x00, 0x0f])
    }
    let narrow = Decompiler(script: CompiledScript(), options: RebuildOptions(terms: terms))
    _ = narrow.actor(deep, "top", [])
    #expect(narrow.diagnostics.count { $0.message.contains("inside one another") } == 1)
    #expect(narrow.actorsBeingRebuilt.isEmpty)

    // A plain one is rebuilt, with no report.
    let plain = Decompiler(script: CompiledScript(), options: RebuildOptions(terms: terms))
    let object = plain.actor(initializer("s", literals: [], code: [0x6b, 0xb0, 0x4f, 0x0f]), "s", [])
    #expect(object.name == "s" && plain.diagnostics.isEmpty && plain.actorBudget == maximumScriptObjectsInHandlers - 1)
}

// MARK: - Instructions and diagnostics without end

/**
 What is made from one instruction takes about 300 times its size, so
 a script is read up to a number of instructions, all its handlers
 together: 4 MB of made-up code took more than 1 GB. The handler where
 the number is reached is cut, the ones after it are empty, and that is
 reported once.
 */
@Test func `a script is read up to a number of instructions`() throws {
    let terms = try Registry.default()
    // `1`, `2`, `3`, each one a statement, then `Return`.
    let code: [UInt8] = [0x6b, 0x4f, 0x6c, 0x4f, 0x6d, 0x4f, 0x0f]
    func handler(_ decompiler: Decompiler, _ name: String) throws -> [String] {
        let body = try decompiler.function(Function(offset: 2, name: bytes(name), code: code), []).body
        return body.compactMap { (($0 as? AST.Expression)?.value as? NumberLiteral)?.integer }.map { String($0) }
    }
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions(terms: terms))
    #expect(decompiler.instructionBudget == maximumInstructions)
    decompiler.instructionBudget = 11
    #expect(try handler(decompiler, "first") == ["1", "2", "3"])
    #expect(decompiler.instructionBudget == 4 && decompiler.diagnostics.isEmpty)
    // Four instructions are left: two statements of the second handler.
    #expect(try handler(decompiler, "second") == ["1", "2"])
    #expect(try handler(decompiler, "third").isEmpty)
    #expect(decompiler.instructionBudget == 0)
    #expect(decompiler.diagnostics.map(\.message) == ["the script has more than \(maximumInstructions) instructions: the rest of its code is not read"])

    // In strict mode this is an error.
    let strict = Decompiler(script: CompiledScript(), options: RebuildOptions(strict: true, terms: terms))
    strict.instructionBudget = 3
    #expect(throws: ScriptError.self) {
        _ = try strict.function(Function(offset: 2, name: bytes("first"), code: code), [])
    }
}

/**
 Damaged code can give a diagnostic for each of its bytes: a megabyte
 of them took 600 MB. The first ones are kept, and a last line tells
 how many more there were.
 */
@Test func `diagnostics are kept up to a number`() throws {
    let decompiler = try Decompiler(script: CompiledScript(), options: RebuildOptions(terms: Registry.default()))
    // The same message for each byte of the code, then a problem of another kind.
    for offset in 0 ..< 5000 {
        decompiler.report(2, at: offset, "expression stack underflow")
    }
    decompiler.report(2, "blocks are nested too deep")
    #expect(decompiler.diagnostics.count == maximumRepeatedDiagnostics + 1)
    #expect(decompiler.diagnostics.last?.message == "blocks are nested too deep")
    let all = decompiler.allDiagnostics
    #expect(all.count == maximumRepeatedDiagnostics + 2)
    #expect(all.last?.description == "decompile: \(5000 - maximumRepeatedDiagnostics) more problems are not listed: "
        + "a problem is listed \(maximumRepeatedDiagnostics) times at most, and \(maximumDiagnostics) problems in all")

    // Messages that are all different: the number kept in all.
    let other = try Decompiler(script: CompiledScript(), options: RebuildOptions(terms: Registry.default()))
    for index in 0 ..< maximumDiagnostics + 250 {
        other.report(2, at: index, "problem \(index)")
    }
    #expect(other.diagnostics.count == maximumDiagnostics && other.diagnosticsLeftOut == 250)
    #expect(other.diagnosticCounts.count == maximumDiagnostics)
    #expect(other.allDiagnostics.count == maximumDiagnostics + 1)
    // With no more than the limits, nothing is added.
    #expect(try Decompiler(script: CompiledScript(), options: RebuildOptions(terms: Registry.default())).allDiagnostics.isEmpty)
}

/**
 The names of a table around a function are asked by their place, and
 as a set that is made once.
 */
@Test func `a scope gives its names by place and as a set`() throws {
    let scope: NameScope = ["alpha", "beta", "alpha"]
    #expect(scope.count == 3 && scope[1] == "beta" && scope.names == ["alpha", "beta", "alpha"])
    #expect(scope.contains("alpha") && scope.contains("beta") && !scope.contains("Alpha") && !scope.contains(""))
    #expect(NameScope([]).count == 0 && !NameScope([]).contains("alpha"))

    // A local named like a name of a table around the handler is declared, whatever the table.
    let state = try contractState()
    _ = state.parentVariable(1, 0)
    #expect(state.parentScopes.contains { $0.contains("far1") } && !state.parentScopes.contains { $0.contains("first") })
}

// MARK: - Parts of a pattern that print one value again

/**
 The parts of a pattern that is not one are written as a statement
 each, and each one prints the value again. They are counted like any
 other statement: 40,000 parts of one value of 2,000 operands, 277 KB of
 code, printed 313 MB.
 */
@Test func `the parts of a pattern are counted like other statements`() throws {
    let s = try contractState()
    let big = List(elements: (0 ..< 5000).map { Variable(name: "x\($0)") })
    s.push(big)
    for index in 0 ..< 200 {
        let accessor = Specifier(kind: .index, object: Keyword(fallback: "item"), container: big, from: NumberLiteral(integer: 1))
        s.patternParts.append(PatternPart(target: Variable(name: "a\(index)"), path: [.item(1)], accessor: accessor, isCopy: index % 2 == 1))
    }
    s.flushPatternParts()
    #expect(s.patternParts.isEmpty && s.handler.body.count == 200)
    let comments = s.handler.body.count(where: hasMark)
    #expect(comments > 100 && comments < 200 && s.reportedTooLarge)
    // The first ones are whole: a `set`, then a `copy`. The last ones keep their name and lose the value.
    #expect(s.handler.body[0] is SetStmt && s.handler.body[1] is Copy && !hasMark(s.handler.body[0]))
    #expect(((s.handler.body[198] as? SetStmt)?.target as? Variable)?.name == "a198")

    // A few parts of a small value are all written.
    let small = try contractState()
    for index in 0 ..< 3 {
        let accessor = Specifier(kind: .index, object: Keyword(fallback: "item"), container: Variable(name: "x"), from: NumberLiteral(integer: 1))
        small.patternParts.append(PatternPart(target: Variable(name: "a\(index)"), path: [.item(1)], accessor: accessor, isCopy: false))
    }
    small.flushPatternParts()
    #expect(small.handler.body.count == 3 && small.handler.body.allSatisfy { $0 is SetStmt } && !small.reportedTooLarge)
}

// MARK: - Values and texts that are written again

/** The number of `«value too large»` marks in an expression, and the number of its nodes. */
private func marksAndNodes(_ expression: any Expr) -> (marks: Int, nodes: Int) {
    var marks = 0
    var nodes = 0
    func count(_ node: any Expr) {
        nodes += 1
        if (node as? Keyword)?.fallback == "«value too large»" {
            marks += 1
        }
        node.children.forEach(count)
    }
    count(expression)
    return (marks, nodes)
}

/**
 A value that uses one small list twice at each level, 60 levels deep.
 In full it has 2^60 items. Each list is written in full once; what is
 written again stops at the budget.
 */
@Test func `a value that repeats one container is cut`() {
    var value = Value.vector(Vector(children: [.integer(1), .integer(2)]))
    for _ in 0 ..< 60 {
        value = .vector(Vector(children: [value, value]))
    }
    var path = LiteralPath(budget: 5000)
    let result = path.literal(value)
    #expect(path.budget == 0 && path.cut > 0)
    let found = marksAndNodes(result)
    #expect(found.marks > 0 && found.marks == path.cut)
    #expect(found.nodes < 20000)
    // The first of the two sides is whole at every level: 61 lists, one inside the other.
    var depth = 0
    var side: any Expr? = result
    while let list = side as? List {
        depth += 1
        side = list.elements.first ?? nil
    }
    #expect(depth == 61 && (side as? NumberLiteral)?.integer == 1)
}

/**
 All the conversions of one decompilation share the budgets. A value is
 written in full the first time, whatever is left of them, and a small
 one every time: so a large value cannot hide what comes after it.
 */
@Test func `a value is whole the first time, and a small one every time`() {
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions())
    decompiler.literalPath.budget = 3
    let pair = Value.vector(Vector(children: [.integer(1), .integer(2)]))
    // The first time takes nothing. The second time takes three: the list and its two items.
    #expect((decompiler.literal(pair, in: 2) as? List)?.elements.count == 2 && decompiler.literalPath.budget == 3)
    #expect((decompiler.literal(pair, in: 2) as? List)?.elements.count == 2 && decompiler.literalPath.budget == 0)
    // Nothing is left, and the small list is still written.
    for _ in 0 ..< 5 {
        #expect(marksAndNodes(decompiler.literal(pair, in: 2)) == (0, 3))
    }
    #expect(decompiler.diagnostics.isEmpty && decompiler.literalPath.cut == 0)

    // A list of 20 items: whole the first time, then its first items and one mark for the rest.
    let twenty = Value.vector(Vector(children: (0 ..< 20).map { .integer($0) }))
    #expect(marksAndNodes(decompiler.literal(twenty, in: 3)) == (0, 21))
    let again = decompiler.literal(twenty, in: 4)
    #expect(marksAndNodes(again) == (1, 1 + LiteralPath.smallNodes))
    #expect(((again as? List)?.elements.last as? Keyword)?.fallback == "«value too large»")
    _ = decompiler.literal(twenty, in: 5)
    // Said once, for the first value that is not whole.
    #expect(decompiler.diagnostics.count == 1 && decompiler.diagnostics.first?.function == 4)
    #expect(decompiler.diagnostics.first?.message.contains("again and again") == true)

    // A list of a million items, written again: one mark, not a million.
    let million = Value.vector(Vector(children: [Value](repeating: .integer(7), count: 1_000_000)))
    #expect(marksAndNodes(decompiler.literal(million, in: 6)).nodes == 1_000_001)
    #expect(marksAndNodes(decompiler.literal(million, in: 6)) == (1, 1 + LiteralPath.smallNodes))
    // A pair chain and a record stop the same way.
    var chain = Value.null
    var record = Value.null
    for index in 0 ..< 50 {
        chain = .pair(Pair(head: .integer(Int64(index)), tail: chain))
        record = .binding(Binding(key: .bytes(Array("k\(index)".utf8)), value: .integer(Int64(index)), next: record))
    }
    #expect((decompiler.literal(chain, in: 7) as? List)?.elements.count == 50)
    #expect((decompiler.literal(chain, in: 7) as? List)?.elements.count == LiteralPath.smallNodes)
    #expect((decompiler.literal(record, in: 7) as? Record)?.fields.count == 50)
    #expect(((decompiler.literal(record, in: 7) as? Record)?.fields.count ?? 99) <= LiteralPath.smallNodes)

    // After all that, a value that was never written is whole.
    let fresh = Value.vector(Vector(children: (0 ..< 5000).map { .integer($0) }))
    #expect(marksAndNodes(decompiler.literal(fresh, in: 8)) == (0, 5001))
}

/**
 One long text used by every statement: a megabyte of text and a
 thousand statements are a gigabyte. A text is written in full the
 first time; written again, it takes from a budget of bytes. When that
 is used up, a short text is still written, and a long one prints as
 its first characters.
 */
@Test func `a long text written again is cut to its start`() {
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions())
    decompiler.literalPath.byteBudget = 1000
    let long = Value.bytes(Array(("curl -s https://example.com/a\nb\t" + String(repeating: "x", count: 570)).utf8))
    let short = Value.bytes(Array(String(repeating: "y", count: 200).utf8))
    func text(_ value: Value) -> String? {
        (decompiler.literal(value, in: 2) as? StringLiteral)?.value
    }
    #expect(text(long)?.count == 602 && decompiler.literalPath.byteBudget == 1000)
    #expect(text(long)?.count == 602 && decompiler.literalPath.byteBudget == 398)
    // 602 bytes are more than what is left.
    let cut = decompiler.literal(long, in: 3) as? Keyword
    #expect(cut?.fallback == "«long text, 602 bytes: \"curl -s https://example.com/a b " + String(repeating: "x", count: 32) + "…\"»")
    #expect(decompiler.literalPath.cut == 1 && decompiler.diagnostics.count == 1)
    // A short text is written every time, and a new long one the first time.
    #expect(text(short)?.count == 200 && text(short)?.count == 200)
    decompiler.literalPath.byteBudget = 0
    #expect(text(short)?.count == 200)
    #expect(text(.bytes(Array(String(repeating: "z", count: 5000).utf8)))?.count == 5000)

    // Text stored as UTF-16, in a text object, and data.
    let wide = UnicodeText(text: Array(repeating: [0, 65], count: 300).flatMap(\.self), style: [])
    #expect(text(.unicodeText(wide))?.count == 300)
    #expect((decompiler.literal(.unicodeText(wide), in: 2) as? Keyword)?.fallback.hasPrefix("«long text, 600 bytes: \"AAAA") == true)
    let object = Vector(type: 177, hasType: true, children: [.null, .unicodeText(wide)])
    #expect((decompiler.literal(.vector(object), in: 2) as? Keyword)?.fallback.hasPrefix("«long text, 600 bytes") == true)
    let data = Value.rawData(Array("TEXT".utf8) + [UInt8](repeating: 1, count: 300))
    #expect(decompiler.literal(data, in: 2) is RawDataLiteral)
    #expect((decompiler.literal(data, in: 2) as? Keyword)?.fallback == "«long data, 304 bytes»")
    // Inside a list that is written again, a long text is cut too.
    let list = Value.vector(Vector(children: [.bytes(Array(String(repeating: "w", count: 400).utf8)), .integer(1)]))
    #expect(((decompiler.literal(list, in: 2) as? List)?.elements.first as? StringLiteral)?.value.count == 400)
    #expect(((decompiler.literal(list, in: 2) as? List)?.elements.first as? Keyword)?.fallback.hasPrefix("«long text, 400 bytes") == true)
}

/**
 A conversion on its own, for a name or a label, has a small budget:
 a name is asked for every variable, and each one had four million
 values to write.
 */
@Test func `a name does not convert a large value`() {
    var value = Value.vector(Vector(children: [.integer(1), .integer(2)]))
    for _ in 0 ..< 60 {
        value = .vector(Vector(children: [value, value]))
    }
    #expect(Value.object(value).identifier(or: "var_1") == "var_1")
    #expect(Value.object(.constant(0x706e_616d)).identifier(or: "var_1") == "name")
    #expect(marksAndNodes(value.literal).nodes < 5000)
}

// MARK: - Statements that print one text again

/**
 One text of a megabyte, kept on the stack and used by 3,000
 statements: 12 KB of code printed 2.9 GB. The bytes of text that
 statements print again are counted for the whole script. Past the
 limit, a statement that prints a long text again is left out; a
 statement with a short text, or with a new one, is written.
 */
@Test func `statements that print one long text again are left out`() throws {
    let s = try contractState()
    let long = StringLiteral(value: String(repeating: "a", count: 100_000))
    s.push(long)
    #expect(s.text(of: long) == 100_000 && s.distinctText == 100_000)
    s.decompiler.repeatedText = maximumRepeatedText - 250_000
    for _ in 0 ..< 10 {
        s.push(Unary(op: .not, value: long))
        s.flushExpression()
    }
    // The first one prints the text for the first time. The next two fit
    // in what is left, 250,000 bytes; the fourth one does not.
    let kinds = s.handler.body.map(hasMark)
    #expect(kinds == [false, false, false, true, true, true, true, true, true, true])
    #expect(s.decompiler.diagnostics.count { $0.message.contains("same long texts") } == 1)
    #expect(!s.reportedTooLarge)

    // A short text again, and a new long text: both are written.
    let short = StringLiteral(value: "curl")
    for _ in 0 ..< 3 {
        s.push(Unary(op: .not, value: short))
        s.flushExpression()
    }
    s.push(StringLiteral(value: String(repeating: "b", count: 100_000)))
    s.flushExpression()
    #expect(s.handler.body.suffix(4).allSatisfy { !hasMark($0) })
    #expect(s.handler.body.count == 14)
}

/**
 `Dup, Concatenate` on a long text doubles it at each step, with one
 more node. The text of an expression is compared with the text of all
 the nodes of the handler.
 */
@Test func `an expression that doubles a text is replaced`() throws {
    let s = try contractState()
    var value: any Expr = StringLiteral(value: String(repeating: "a", count: 10000))
    s.push(value)
    var replaced = 0
    for step in 1 ... 12 {
        value = Binary(op: .concatenate, left: value, right: value)
        s.push(value)
        if (s.stack.last as? Keyword)?.fallback == "«expression too large»" {
            replaced = step
            break
        }
    }
    // 20,000 bytes are twice the text there is; 40,000 are more.
    #expect(replaced == 2 && s.reportedTooLarge)

    // Texts that are all different can be joined without end.
    let honest = try contractState()
    var joined: any Expr = StringLiteral(value: String(repeating: "a", count: 10000))
    for _ in 0 ..< 50 {
        joined = Binary(op: .concatenate, left: joined, right: StringLiteral(value: String(repeating: "b", count: 10000)))
        honest.push(joined)
    }
    #expect(honest.stack.allSatisfy { $0 is Binary } && !honest.reportedTooLarge)
    #expect(honest.text(of: joined) == 510_000)
}

/**
 Once a handler is too large to print, only a statement that prints a
 large part again is left out. A statement of its own is written, so
 that nothing can be hidden behind the statements that used up the
 limit.
 */
@Test func `a new statement is written in a handler that is too large`() throws {
    let s = try contractState()
    let big = List(elements: (0 ..< 5000).map { Variable(name: "x\($0)") })
    s.push(big)
    for _ in 0 ..< 200 {
        s.push(Binary(op: .add, left: big, right: NumberLiteral(integer: 1)))
        s.flushExpression()
    }
    #expect(s.reportedTooLarge && s.handler.body.last.map(hasMark) == true)
    // A statement that was never printed, small or large.
    s.push(CommandCall(name: "do shell script", arguments: [DirectArgument(value: StringLiteral(value: "curl"))]))
    s.flushExpression()
    s.push(List(elements: (0 ..< 3000).map { Variable(name: "y\($0)") }))
    s.flushExpression()
    #expect(s.handler.body.suffix(2).allSatisfy { $0 is AST.Expression })
    // A small part printed again is written too.
    let small = Variable(name: "z")
    for _ in 0 ..< 3 {
        s.push(Unary(op: .not, value: small))
        s.flushExpression()
    }
    #expect(s.handler.body.suffix(3).allSatisfy { $0 is AST.Expression })
    // The large one again: a mark stands for it, and what is new next to it is written.
    let command = CommandCall(name: "do shell script", arguments: [DirectArgument(value: StringLiteral(value: "the new text"))])
    s.push(Binary(op: .concatenate, left: command, right: big))
    s.flushExpression()
    let last = try #require((s.handler.body.last as? AST.Expression)?.value as? Binary)
    #expect(last.left === command && (last.right as? Keyword)?.fallback == printedAboveMark)
    #expect(s.handler.body.allSatisfy { !($0 is AST.Comment) })
}
