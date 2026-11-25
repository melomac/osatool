import AST
import Bytecode
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Terminology
import Testing

/** Returns a stored list pattern: a vector of class 4 around the items. */
private func listPattern(_ items: Value...) -> Value {
    let list = Value.vector(Vector(hasType: true, children: [.null] + items))
    return .vector(Vector(type: 4, hasType: true, children: [.null, .integer(Int64(items.count)), list]))
}

/** Returns a chain of bindings, one for each label and value. */
private func bindings(_ fields: (label: Value, value: Value)...) -> Value {
    var chain = Value.pair(Pair(empty: true))
    for field in fields.reversed() {
        chain = .binding(Binding(key: field.label, value: field.value, next: chain))
    }
    return chain
}

/** Returns the header of the handler rebuilt from `function`, with the default terminology. */
private func header(_ function: Function) throws -> String {
    let terms = try Registry.default()
    let script = CompiledScript()
    let decompiler = Decompiler(script: script, options: RebuildOptions(strict: true, terms: terms))
    let source = try format(Script(handlers: [decompiler.function(function, [])]), terms: terms)
    return String(source.prefix { $0 != "\n" })
}

@Test func `stored parameter patterns`() throws {
    var reader = ParameterReader()
    // No parameter: the stored nil, an empty list cell, or an empty record.
    let empty: [Value] = [.null, .pair(Pair(empty: true)), .binding(Binding(empty: true))]
    for value in empty {
        let pattern = reader.pattern(value)
        #expect(pattern == nil, "\(value.typeName)")
    }

    let scalar = reader.pattern(bytes("argv"))
    guard case .name? = scalar else {
        Issue.record("a byte string is a name")
        return
    }
    #expect(scalar?.nameCount == 1)

    // {a, {b, c}, {x:d}}
    let record = bindings((bytes("x"), bytes("d")))
    let nested = reader.pattern(listPattern(bytes("a"), listPattern(bytes("b"), bytes("c")), record))
    let pattern = try #require(nested)
    #expect(pattern.nameCount == 4)
    var names = ParameterNames(variables: ["a", "b", "c"])
    let expression = try #require(pattern.expr(&names) as? List)
    #expect((expression.elements[0] as? Variable)?.name == "a")
    #expect(((expression.elements[1] as? List)?.elements[1] as? Variable)?.name == "c")
    // The list of variables is too short for the fourth name.
    #expect(((expression.elements[2] as? Record)?.fields[0].value as? Variable)?.name == "arg_3")
}

/** A vector that holds itself three times must not make the reader loop. */
@Test func `stored parameter patterns are read within limits`() {
    let loop = Vector(type: 4, hasType: true)
    let items = Vector(hasType: true, children: [.null, .vector(loop), .vector(loop), .vector(loop)])
    loop.children = [.null, .integer(3), .vector(items)]
    var reader = ParameterReader()
    let pattern = reader.pattern(.vector(loop))
    #expect(pattern != nil)
    #expect(reader.budget <= 0)
    // Every value over the limit is one name.
    #expect((pattern?.nameCount ?? 0) > 0)
}

/** One header for each form of the parameters of a handler. */
@Test func `handler headers from stored parameters`() throws {
    let return1: [UInt8] = [0x0f]
    func function(_ name: Value, _ arguments: Value, _ labels: Value, _ variables: String...) -> Function {
        Function(offset: 2, name: name, arguments: arguments, labels: labels, variables: variables.map { bytes($0) }, code: return1)
    }
    let none = Value.pair(Pair(empty: true))
    let run = eventIdentifier("aevt", "oapp")

    #expect(try header(function(bytes("mix"), listPattern(bytes("a"), bytes("b")), none, "a", "b")) == "on mix(a, b)")
    #expect(try header(function(bytes("describe"), none, none)) == "on describe()")
    #expect(try header(function(bytes("polish"), none, bindings((code("to  "), bytes("x"))), "x")) == "on polish to x")
    #expect(try header(function(
        bytes("findNumbers"), bytes("numberList"),
        bindings((code("abve"), bytes("minLimit")), (bytes("rounding"), bytes("roundBoolean"))),
        "numberList", "minLimit", "roundBoolean",
    )) == "on findNumbers of numberList above minLimit given rounding:roundBoolean")
    #expect(try header(function(
        bytes("spread"), listPattern(bytes("a"), bytes("b")), bindings((code("by  "), bytes("y"))), "a", "b", "y",
    )) == "on spread of {a, b} by y")
    #expect(try header(function(bytes("pat"), listPattern(bytes("a"), listPattern(bytes("b"), bytes("c"))), none, "a", "b", "c"))
        == "on pat(a, {b, c})")

    #expect(try header(function(run, .null, none)) == "on run")
    #expect(try header(function(run, bytes("argv"), none, "argv")) == "on run argv")
    #expect(try header(function(run, listPattern(bytes("a"), bytes("b")), none, "a", "b")) == "on run {a, b}")
}

/**
 The labels of an event handler are stored with the function, so they
 are read, not guessed from the names of the variables.
 */
@Test func `event handler headers from stored parameters`() throws {
    func function(_ event: Value, _ arguments: Value, _ labels: Value, _ variables: String...) -> Function {
        Function(
            offset: 2, name: event, arguments: arguments, labels: labels,
            variables: variables.map { bytes($0) }, code: [0x0f],
        )
    }
    // A command of Standard Additions: its words can be used anywhere.
    #expect(try header(function(
        eventIdentifier("syso", "dlog"), bytes("msg"),
        bindings((code("btns"), bytes("b")), (code("dflt"), bytes("d"))), "msg", "b", "d",
    )) == "on display dialog msg buttons b default button d")
    #expect(try header(function(eventIdentifier("GURL", "GURL"), bytes("theURL"), .pair(Pair(empty: true)), "theURL")) == "on open location theURL")

    // A command of Mail: its words compile only inside `using terms
    // from`, so the handler is printed in such a block. The names of
    // the variables do not matter.
    let terms = try Registry.default()
    let rule = function(eventIdentifier("emal", "cpma"), bytes("a"), bindings((code("pmar"), bytes("b"))), "a", "b")
    let decompiler = Decompiler(script: CompiledScript(), options: RebuildOptions(strict: true, terms: terms))
    let source = try format(Script(handlers: [decompiler.function(rule, [])]), terms: terms)
    #expect(source == """
    using terms from application "Mail"
        on perform mail action with messages a for rule b
        end perform mail action with messages
    end using terms from

    """)

    // A command that no dictionary has: the raw form.
    #expect(try header(function(
        eventIdentifier("zzzz", "yyyy"), bytes("a"), bindings((code("pmar"), bytes("b"))), "a", "b",
    )) == "on «event zzzzyyyy» a given «class pmar»:b")
}

/**
 Without strict mode, a problem is recorded and the work goes on. A
 decoding problem met while decompiling is reported by the decompile
 stage, with the function and the position of the instruction.
 */
@Test func `diagnostics of a handler`() throws {
    let script = CompiledScript()
    let decompiler = Decompiler(script: script, options: RebuildOptions())
    // Opcode 97 (PushLiteralExtended) needs two more bytes; one is missing.
    let function = Function(offset: 5, name: bytes("cut"), code: [0x0f, 97, 0])
    _ = try decompiler.function(function, [])
    let decoding = try #require(decompiler.diagnostics.first)
    #expect(decoding.stage == .decompile)
    #expect(decoding.function == 5 && decoding.offset == 1)
    #expect(decoding.description.hasPrefix("decompile at 0x1: "))

    // A problem that is not about one instruction has no position.
    decompiler.report(5, "something else")
    #expect(decompiler.diagnostics.last?.offset == nil)
    #expect(decompiler.diagnostics.last?.description == "decompile: something else")
}

@Test func `function name recovery`() throws {
    var function = bytes("helper").functionName(nil)
    try #require(function.name == "helper" && function.event == nil && !function.isRun, "function name")
    let eventValue = eventIdentifier("aevt", "oapp")
    function = eventValue.functionName(nil)
    try #require(function.name == "run" && function.event != nil && function.isRun, "run event")
}
