import AST
import Bytecode
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Terminology
import Testing

@Test func `run decompiles discovered actor table`() throws {
    let actorName = bytes("AppDelegate")
    let propertyName = bytes("ready")
    let handlerName = bytes("clicked_")
    let function = Function(offset: 4, name: handlerName, arguments: .null, code: [0x0f])
    let table = ScriptTable(
        path: "root[2].vector[4]", entryOffset: 2, name: actorName,
        names: [bytes("object"), propertyName, handlerName],
        entries: [
            Entry(offset: 2, name: bytes("object"), value: .null),
            Entry(offset: 3, name: propertyName, value: .special(Special.false)),
            Entry(offset: 4, name: handlerName, value: .vector(function.raw), kind: .function(function)),
        ],
    )
    // The script table has one entry: the script object.
    let entry = Entry(offset: 2, name: actorName, value: .null, kind: .scriptObjects([table]))
    let script = CompiledScript(table: ScriptTable(names: [actorName], entries: [entry]))

    let result = try Decompilation.run(script, options: RebuildOptions())
    try #require(result.script.properties.isEmpty, "actor placeholder leaked into root properties")
    try #require(result.script.objects.count == 1, "objects")
    let object = result.script.objects[0]
    // `object` is an ordinary name: a property with that name is kept.
    try #require(object.name == "AppDelegate" && object.properties.map(\.name) == ["object", "ready"], "object")
    try #require(object.handlers.count == 1 && object.handlers[0].name == "clicked_", "handlers")
}

/**
 A property whose name is a code is kept, at the top level and in a
 script object. The codes `pimr` and `pare` are not property names.
 */
@Test func `properties named with a code are kept`() throws {
    let names = [code("ptsz"), code("pnam"), code("pare"), bytes("plain")]
    let values: [Value] = [.integer(3), bytes("top"), .null, .integer(1)]
    let table = ScriptTable(names: names, entries: names.indices.map { Entry(offset: $0 + 2, name: names[$0], value: values[$0]) })
    // The value of the parent is kept beside the table, not in it.
    table.parent = bytes("someone")
    let script = CompiledScript(table: table)
    let result = try Decompilation.run(script, options: RebuildOptions(strict: true))
    let properties = result.script.properties
    try #require(properties.count == 4)
    #expect(properties[0].keyword?.code == .four("ptsz"))
    #expect(properties[1].keyword?.fallback == "name")
    #expect(properties[2].keyword?.fallback == "parent")
    #expect((properties[2].value as? StringLiteral)?.value == "someone")
    #expect(properties[3].name == "plain")
}

/** Returns the body of the handler rebuilt from some bytecode, as source lines. */
private func body(_ code: [UInt8], literals: [Value] = [], variables: [String] = [], name: Value? = nil, isTopLevel: Bool = false) throws -> [String] {
    let terms = try Registry.default()
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions(strict: true, terms: terms))
    let function = Function(
        offset: 2, name: name ?? bytes("f"), variables: variables.map { bytes($0) }, literals: literals, code: code,
    )
    let handler = try decompiler.function(function, [], isTopLevel: isTopLevel)
    let source = format(Script(handlers: [handler]), terms: terms)
    return source.split(separator: "\n").dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
}

/**
 In a handler a name is local, and a global is read with `PushGlobal`.
 So a name read that way was declared with `global`.

 ```
 PushGlobal "g"   PopVariable 0   StoreResult   PushVariable 0   Return
 ```
 */
@Test func `a handler declares the globals it uses`() throws {
    let code: [UInt8] = [0xc0, 0xb0, 0x4f, 0xa0, 0x0f, 0x0f]
    #expect(try body(code, literals: [bytes("g")], variables: ["x"]) == ["global g", "set x to g", "return x"])
    // A global named by a code (`result`, `text item delimiters`) is not a variable.
    #expect(try body([0xc0, 0x0f, 0x0f], literals: [.object(.constant(0x7273_6c74))]) == ["return result"])
    // The same code in the run handler of a script object is a handler like another.
    let run = Value.object(.eventIdentifier(EventIdentifier(fields: ["aevt", "oapp", "null", Code4(), "****", Code4()])))
    #expect(try body(code, literals: [bytes("g")], variables: ["x"], name: run) == ["global g", "set x to g", "return x"])
}

/**
 In the run handler of the script it is the other way: a name is global,
 and a local was declared with `local`.
 */
@Test func `the run handler of the script declares its locals`() throws {
    let run = Value.object(.eventIdentifier(EventIdentifier(fields: ["aevt", "oapp", "null", Code4(), "****", Code4()])))
    let code: [UInt8] = [0xc0, 0xb0, 0x4f, 0xa0, 0x0f, 0x0f]
    let lines = try body(code, literals: [bytes("g")], variables: ["x"], name: run, isTopLevel: true)
    #expect(lines == ["local x", "set x to g", "return x"])
}

/** The variable of a `repeat`, the variables of `on error` and the parameters are local without a line. */
@Test func `bound variables need no declaration`() throws {
    let terms = try Registry.default()
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions(terms: terms))
    let function = Function(offset: 2, variables: [bytes("argv"), bytes("i"), bytes("msg"), bytes("kept")], code: [0x0f])
    let state = State(decompiler: decompiler, function: function, handler: Handler(), variables: ["argv", "i", "msg", "kept"])
    for index in 0 ..< 4 {
        _ = state.local(index)
    }
    let handler = Handler(
        name: "run", parameters: [Parameter(name: "argv")],
        body: [Repeat(kind: .range, variable: "i", body: [Try(errorName: "msg")])], isRunHandler: true,
    )
    let declarations = decompiler.declarations(of: handler, state, isTopLevelRun: true)
    #expect((declarations.first as? Declaration)?.names == ["kept"])
    #expect((declarations.first as? Declaration)?.global == false)
    // In another handler, the same locals need no line at all.
    #expect(decompiler.declarations(of: handler, state, isTopLevelRun: false).isEmpty)
}

/**
 A script object linked to the script around it, with no property or
 script object read anywhere: a `global` line outside the handlers
 explains the link.
 */
@Test func `a global line explains a linked script object`() {
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions())
    let outer = Vector()
    let linked = ScriptTable(raw: Vector(children: [.vector(outer), .null]))
    let table = ScriptTable(raw: outer, entries: [Entry(offset: 2, name: nil, value: .null, kind: .scriptObjects([linked]))])
    let reader = Handler(name: "reader")
    let inside = Handler(name: "inside")
    let object = ScriptObject(name: "worker", handlers: [inside])
    let members: [Member] = [.object(object), .handler(reader)]
    func line() -> [String]? {
        guard case let .globals(declaration)? = decompiler.globalsLine(for: members, of: table, names: ["worker", "reader"]) else {
            return nil
        }
        return declaration.names
    }

    // No global is used: nothing to declare.
    #expect(line() == nil)
    // The globals used inside the script object come first.
    decompiler.handlerUse[ObjectIdentifier(reader)] = (["shared", "other"], [], 0)
    #expect(line() == ["shared", "other"])
    decompiler.handlerUse[ObjectIdentifier(inside)] = (["shared"], ["mine"], 0)
    #expect(line() == ["shared"])
    // A name that the script object uses as its own variable is not declared outside.
    decompiler.handlerUse[ObjectIdentifier(inside)] = ([], ["shared"], 0)
    #expect(line() == ["other"])
    // A name of the table read somewhere explains the link: no line.
    decompiler.handlerUse[ObjectIdentifier(reader)] = (["shared"], [], 1)
    #expect(line() == nil)
    decompiler.handlerUse[ObjectIdentifier(reader)] = (["shared"], [], 0)
    decompiler.handlerUse[ObjectIdentifier(inside)] = ([], [], 2)
    #expect(line() == nil)
    // Depth 1 inside the script object is its own table, not the one around.
    decompiler.handlerUse[ObjectIdentifier(inside)] = ([], [], 1)
    #expect(line() == ["shared"])
    // A script object without the link needs no line.
    let free = ScriptTable(entries: [Entry(offset: 2, name: nil, value: .null, kind: .scriptObjects([ScriptTable()]))])
    #expect(decompiler.globalsLine(for: members, of: free, names: []) == nil)
}

/**
 `script s` … `end script` is a statement that names its variable
 itself. The compiler ends it with `PopVariable`, like an assignment.
 When a block or the handler ends right after it, the value is still
 waiting for its target: it must not become `set s to script s`, which
 does not compile.
 */
@Test func `a script object waiting for its variable is a statement`() throws {
    do {
        // The block ends: `tell x` … `script s` … `end tell`.
        let state = try contractState()
        let object = ScriptObject(name: "s")
        state.pending = Variable(name: "s")
        state.stack = [object]
        state.flushPendingExpression()
        #expect(state.pending == nil && state.stack.isEmpty)
        #expect(state.handler.body.count == 1 && (state.handler.body.first as? AST.Expression)?.value === object)
    }
    do {
        // The handler ends.
        let state = try contractState()
        let object = ScriptObject(name: "s")
        state.pending = Variable(name: "s")
        state.stack = [object]
        state.returnValue(isLast: true)
        #expect(state.pending == nil)
        #expect(state.handler.body.count == 1 && (state.handler.body.first as? AST.Expression)?.value === object)
    }
    do {
        // Any other value is assigned.
        let state = try contractState()
        state.pending = Variable(name: "s")
        state.stack = [NumberLiteral(integer: 1)]
        state.flushPendingExpression()
        let set = try #require(state.handler.body.first as? SetStmt)
        #expect((set.target as? Variable)?.name == "s" && (set.value as? NumberLiteral)?.integer == 1)
    }
}

/**
 The name of a script object made by a statement is local with no
 `local` line: the compiler refuses `local s` before `script s`.
 */
@Test func `the name of a script statement needs no declaration`() throws {
    let terms = try Registry.default()
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions(terms: terms))
    let function = Function(offset: 2, variables: [bytes("s"), bytes("kept")], code: [0x0f])
    let state = State(decompiler: decompiler, function: function, handler: Handler(), variables: ["s", "kept"])
    _ = state.local(0)
    _ = state.local(1)
    let inside: [any Stmt] = [AST.Expression(value: ScriptObject(name: "s"))]
    let handler = Handler(name: "run", body: [Tell(target: Variable(name: "x"), body: inside)], isRunHandler: true)
    let declarations = decompiler.declarations(of: handler, state, isTopLevelRun: true)
    #expect((declarations.first as? Declaration)?.names == ["kept"])
}

/**
 `property parent : a` of a script object made inside a handler: the
 value, then `DefineProperty` with the code `pare`.
 */
@Test func `the parent of a script object made in a handler is kept`() throws {
    let state = try contractState(code("pare"))
    state.stack = [Variable(name: "a")]
    state.defineProperty(0)
    #expect(state.stack.isEmpty)
    let set = try #require(state.handler.body.first as? SetStmt)
    #expect((set.target as? Keyword)?.code == .four("pare") && (set.target as? Keyword)?.fallback == "parent")
    #expect((set.value as? Variable)?.name == "a")
    // With nothing on the stack there is nothing to define.
    let empty = try contractState(code("pare"))
    empty.defineProperty(0)
    #expect(empty.handler.body.isEmpty)
}

/**
 The last statement of a block has no `StoreResult` before the block
 ends. `copy x to y` there must still be a copy: it was printed
 `set y to «copy» x`, which does not compile.
 */
@Test func `a copy waiting for its variable is a copy`() throws {
    func waiting() throws -> State {
        let state = try contractState()
        state.pending = Variable(name: "y")
        state.stack = [CopyExpr(value: Variable(name: "x"))]
        return state
    }
    func isCopy(_ state: State) -> Bool {
        guard let copy = state.handler.body.first as? Copy else {
            return false
        }
        return state.handler.body.count == 1 && state.pending == nil && (copy.source as? Variable)?.name == "x"
            && (copy.target as? Variable)?.name == "y"
    }
    // The end of a block, the end of a `try` body, the end of the handler, and `StoreResult`.
    var state = try waiting()
    state.flushPendingExpression()
    #expect(isCopy(state))
    state = try waiting()
    state.flushExpression()
    #expect(isCopy(state))
    state = try waiting()
    state.returnValue(isLast: true)
    #expect(isCopy(state))
    state = try waiting()
    state.storeResult()
    #expect(isCopy(state))
    // A script object at the end of a `try` body is a statement too.
    state = try contractState()
    let object = ScriptObject(name: "s")
    state.pending = Variable(name: "s")
    state.stack = [object]
    state.flushExpression()
    #expect((state.handler.body.first as? AST.Expression)?.value === object && state.pending == nil)
}
