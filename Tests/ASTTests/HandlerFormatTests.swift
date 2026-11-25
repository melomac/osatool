@testable import AST
import Extensions
import Terminology
import Testing

@Test func `raw event handler rendering`() throws {
    let event = try EventCode(parsing: "emalcpma")
    let rule = try Code4(parsing: "pmar")
    let handler = Handler(
        name: "perform mail action with messages",
        eventCode: event,
        parameters: [
            Parameter(name: "theMessages"),
            Parameter(name: "theRule", code: rule),
        ],
        body: [Return(explicit: true)],
    )
    let got = try contractFormatter().handler(handler, 0)
    let want = "on «event emalcpma» theMessages given «class pmar»:theRule\n" +
        "    return\n" +
        "end «event emalcpma»"
    try #require(got == want, "handler =\n\(got)\nwant:\n\(want)")
}

/**
 `display dialog` is a command of Standard Additions. A script can use
 its words without a `tell` block, so the labels are printed as words.
 */
@Test func `event handler of a script command prints its labels as words`() throws {
    let handler = try Handler(
        eventCode: EventCode(parsing: "sysodlog"),
        parameters: [
            Parameter(name: "msg"),
            Parameter(name: "btns", code: Code4(parsing: "btns")),
            Parameter(name: "def", code: Code4(parsing: "dflt")),
        ],
    )
    let got = try contractFormatter().handler(handler, 0)
    #expect(got == "on display dialog msg buttons btns default button def\nend display dialog")
}

/** A label the command does not know keeps the whole header in the raw form. */
@Test func `event handler with an unknown label stays raw`() throws {
    let handler = try Handler(
        eventCode: EventCode(parsing: "sysodlog"),
        parameters: [Parameter(name: "msg"), Parameter(name: "extra", code: Code4(parsing: "zzzz"))],
    )
    let got = try contractFormatter().handler(handler, 0)
    #expect(got == "on «event sysodlog» msg given «class zzzz»:extra\nend «event sysodlog»")
}

@Test func `run handler parameters`() throws {
    let formatter = try contractFormatter()
    let plain = Handler(name: "run", isRunHandler: true)
    #expect(formatter.handler(plain, 0) == "on run\nend run")

    let direct = Handler(name: "run", parameters: [Parameter(name: "argv")], isRunHandler: true)
    #expect(formatter.handler(direct, 0) == "on run argv\nend run")

    let pattern = List(elements: [Variable(name: "input"), Variable(name: "parameters")])
    let list = Handler(name: "run", parameters: [Parameter(pattern: pattern)], isRunHandler: true)
    #expect(formatter.handler(list, 0) == "on run {input, parameters}\nend run")
}

/**
 The header of a user handler with labels: the direct parameter after
 `of`, the prepositions, then the other labels after `given`.
 */
@Test func `user handler with labeled parameters`() throws {
    let handler = try Handler(
        name: "findNumbers",
        parameters: [
            Parameter(name: "numberList"),
            Parameter(name: "minLimit", code: Code4(parsing: "abve")),
            Parameter(name: "roundBoolean", label: .word("rounding")),
            Parameter(name: "n", code: Code4(parsing: "ptsz")),
        ],
    )
    let got = try contractFormatter().handler(handler, 0)
    #expect(got == "on findNumbers of numberList above minLimit given rounding:roundBoolean, size:n\nend findNumbers")
}

@Test func `user handler with a pattern parameter`() throws {
    let record = Record(fields: [RecordField(label: StringLiteral(value: "x"), value: Variable(name: "a"))])
    let list = List(elements: [Variable(name: "b"), Variable(name: "c")])
    let handler = Handler(
        name: "pat",
        parameters: [Parameter(pattern: record), Parameter(pattern: list), Parameter(name: "d")],
    )
    let got = try contractFormatter().handler(handler, 0)
    #expect(got == "on pat({x:a}, {b, c}, d)\nend pat")
}

@Test func `parameter names`() {
    #expect(Parameter(name: "x").names == ["x"])
    let record = Record(fields: [RecordField(label: StringLiteral(value: "k"), value: Variable(name: "b"))])
    let pattern = List(elements: [Variable(name: "a"), record])
    #expect(Parameter(pattern: pattern).names == ["a", "b"])
}

@Test func `known direct event uses event handler syntax`() throws {
    let event = try EventCode(parsing: "aevtodoc")
    let handler = Handler(
        name: "open", eventCode: event,
        parameters: [Parameter(name: "dropped_items")],
        body: [Return(explicit: true)],
    )
    let want = "on open dropped_items\n    return\nend open"
    let got = try contractFormatter().handler(handler, 0)
    try #require(got == want, "event handler = \(got), want \(want)")
}

/** `get` and `set` are statements of the language: an event with their code is written raw. */
@Test func `events that can only be written raw`() throws {
    let f = try contractFormatter()
    let get = CommandCall(code: "coregetd", name: "get", arguments: [DirectArgument(value: NumberLiteral(integer: 1))])
    #expect(f.expr(get, .statement) == "«event coregetd» 1")
    let set = CommandCall(code: "coresetd", arguments: [
        DirectArgument(value: Variable(name: "x")), NamedArgument(code: "data", name: "to", value: NumberLiteral(integer: 2)),
    ])
    #expect(f.expr(set, .statement) == "«event coresetd» x given «class data»:2")
}
