@testable import AST
import Extensions
import Terminology
import Testing

/**
 The parts of a call with labels are printed in the order the language
 asks for, whatever their order in the tree.
 */
@Test func `labeled call layout`() throws {
    let formatter = try contractFormatter()
    let call = try LabeledCall(
        name: "describe",
        direct: Variable(name: "x"),
        arguments: [
            LabeledArgument(label: .word("size"), value: NumberLiteral(integer: 2)),
            LabeledArgument(label: .word("quiet"), value: BooleanLiteral(value: false)),
            LabeledArgument(label: .word("flag"), value: BooleanLiteral(value: true)),
            LabeledArgument(label: .code(Code4(parsing: "to  ")), value: NumberLiteral(integer: 5)),
            LabeledArgument(label: .word("bold"), value: BooleanLiteral(value: true)),
            LabeledArgument(label: .word("wide"), value: BooleanLiteral(value: true)),
        ],
    )
    // `bold` and `size` are words of the language: as names of the user they have bars.
    #expect(formatter.expr(call) == "(describe of x to 5 with flag, |bold| and wide without quiet given |size|:2)")
    // Alone on a line, or after `set … to`, the parentheses are not needed.
    #expect(formatter.expr(call, .statement) == "describe of x to 5 with flag, |bold| and wide without quiet given |size|:2")
}

/** A value that is an operation is put in parentheses. */
@Test func `labeled call values that are operations`() throws {
    let sum = Binary(op: .add, left: Variable(name: "x"), right: NumberLiteral(integer: 1))
    let text = Binary(op: .concatenate, left: Variable(name: "a"), right: StringLiteral(value: "!"))
    let call = try LabeledCall(
        name: "spread", direct: text,
        arguments: [LabeledArgument(label: .code(Code4(parsing: "by  ")), value: sum)],
    )
    #expect(try contractFormatter().expr(call, .statement) == "spread of (a & \"!\") by (x + 1)")
}

/**
 An argument whose label has no word is written after `given`, with a
 colon. Without `given` the source would not compile.
 */
@Test func `command call with a label that has no word`() throws {
    let call = try CommandCall(
        code: EventCode(parsing: "abcdefgh"),
        arguments: [
            DirectArgument(value: NumberLiteral(integer: 2)),
            NamedArgument(code: Code4(parsing: "kfil"), value: NumberLiteral(integer: 3)),
            NamedArgument(code: Code4(parsing: "zzzz"), value: Binary(op: .add, left: NumberLiteral(integer: 1), right: NumberLiteral(integer: 2))),
        ],
    )
    let got = try contractFormatter().expr(call, .statement)
    #expect(got == "«event abcdefgh» 2 given «class kfil»:3, «class zzzz»:(1 + 2)")
}

@Test func `command and handler call contracts`() throws {
    let f = try contractFormatter()
    let badm = try Code4(parsing: "badm")
    let execCode = try EventCode(parsing: "sysoexec")
    let call = CommandCall(code: execCode, name: "do shell script", arguments: [
        DirectArgument(value: StringLiteral(value: "id")),
        FlagArgument(code: badm, name: "administrator privileges", enabled: true),
    ])
    var got = f.expr(call)
    #expect(got == #"(do shell script "id" with administrator privileges)"#, "command = \(got)")
    call.arguments[1] = FlagArgument(code: badm, name: "administrator privileges", enabled: false)
    got = f.expr(call)
    #expect(got == #"(do shell script "id" without administrator privileges)"#, "negative flag = \(got)")
    got = f.expr(CommandCall(name: "activate"))
    #expect(got == "(activate)", "zero argument command = \(got)")
    got = f.expr(CommandCall(name: "path to", arguments: [DirectArgument(value: Me())]))
    #expect(got == "(path to me)", "path to me = \(got)")
    got = f.stmt(ErrorStmt(arguments: [DirectArgument(value: StringLiteral(value: "boom"))]), 1)
    #expect(got == #"    error "boom""#, "error statement = \(got)")
    #expect(f.stmt(ErrorStmt(), 0) == "error")
    got = f.expr(HandlerCall(name: "helper", target: Me()))
    #expect(got == "my helper()", "me handler = \(got)")
    got = f.expr(HandlerCall(name: "length", target: Variable(name: "nsValue")))
    #expect(got == "nsValue's |length|()", "reserved selector = \(got)")
    let objcTarget = Specifier(
        kind: .property,
        object: Variable(name: "NSString"),
        container: CurrentApplication(),
    )
    got = f.expr(HandlerCall(name: "stringWithString_", target: objcTarget, arguments: [Variable(name: "candidate")]))
    // A method of an Objective-C object: one part of the name for each argument.
    #expect(got == "(current application's NSString's stringWithString:candidate)", "specifier receiver = \(got)")
    let objcCall = HandlerCall(name: "stringWithString_", target: objcTarget, arguments: [Variable(name: "candidate")])
    #expect(f.expr(objcCall, .statement) == "current application's NSString's stringWithString:candidate")
    let twoParts = HandlerCall(name: "setValue_forKey_", target: Variable(name: "d"), arguments: [NumberLiteral(integer: 1), StringLiteral(value: "k")])
    #expect(f.expr(twoParts, .statement) == #"d's setValue:1 forKey:"k""#)
    // The same name without a target, or with another count of arguments, is an ordinary call.
    #expect(f.expr(HandlerCall(name: "stringWithString_", arguments: [Variable(name: "x")])) == "stringWithString_(x)")
    #expect(f.expr(HandlerCall(name: "length_", target: Variable(name: "v"))) == "v's length_()")
    // No argument: the owner is written with `'s`, also for a property of something.
    #expect(f.expr(HandlerCall(name: "alloc", target: objcTarget)) == "current application's NSString's alloc()")
}

/**
 A coercion given to a command has parentheses. Without them the
 compiler reads `as` as a parameter of the command, or as a coercion of
 what the command gives back: `osacompile` makes another script from
 `do shell script x as text`.
 */
@Test func `a coercion given to a command has parentheses`() throws {
    let formatter = try contractFormatter()
    let text = Coerce(value: Variable(name: "x"), type: Keyword(code: .four("ctxt")))
    let direct = CommandCall(name: "do shell script", arguments: [DirectArgument(value: text)])
    #expect(formatter.expr(direct, .statement) == "do shell script (x as text)")
    let named = CommandCall(name: "write", arguments: [
        DirectArgument(value: Variable(name: "y")), NamedArgument(code: "refn", name: "to", value: text),
    ])
    #expect(formatter.expr(named, .statement) == "write y to (x as text)")
    // The parameter `as` of the command itself is not a coercion.
    let asParameter = CommandCall(name: "do shell script", arguments: [
        DirectArgument(value: Variable(name: "x")), NamedArgument(code: "rtyp", name: "as", value: Keyword(code: .four("ctxt"))),
    ])
    #expect(formatter.expr(asParameter, .statement) == "do shell script x as text")
    // A coercion inside an operation already has its parentheses.
    let joined = Binary(op: .concatenate, left: StringLiteral(value: "a"), right: text)
    #expect(formatter.expr(CommandCall(name: "log", arguments: [DirectArgument(value: joined)]), .statement) == #"log "a" & (x as text)"#)
}

/**
 A label has a word only when its command gives it one. The word that
 another command has for the same code is not used: after an unknown
 command, `as text` would be read as a coercion.
 */
@Test func `a label without a word of its command is printed raw`() throws {
    let formatter = try contractFormatter()
    let call = CommandCall(code: "abcdefgh", arguments: [
        DirectArgument(value: NumberLiteral(integer: 2)),
        NamedArgument(code: "rtyp", value: Keyword(code: .four("ctxt"))),
        NamedArgument(code: "pnam", value: Variable(name: "v")),
        FlagArgument(code: "flag", enabled: true),
        NamedArgument(code: "nope", value: BooleanLiteral(value: false)),
    ])
    #expect(formatter.expr(call, .statement) == "«event abcdefgh» 2 with «class flag» without «class nope» given «class rtyp»:text, name:v")
    // Without terminology every label is raw.
    #expect(SourceFormatter().expr(call, .statement).hasSuffix("given «class rtyp»:«class ctxt», «class pnam»:v"))
    // With its word, a flag is `with` or `without`, and a label is its word.
    let known = CommandCall(name: "display dialog", arguments: [
        DirectArgument(value: StringLiteral(value: "x")),
        FlagArgument(code: "htxt", name: "hidden answer", enabled: true),
        NamedArgument(code: "zzzz", value: NumberLiteral(integer: 1)),
    ])
    #expect(formatter.expr(known, .statement) == #"display dialog "x" with hidden answer given «class zzzz»:1"#)
    // The labels of `error` are words of the language.
    let error = ErrorStmt(arguments: [
        DirectArgument(value: StringLiteral(value: "boom")), NamedArgument(code: "errn", value: NumberLiteral(integer: 42)),
        NamedArgument(code: "erob", value: Variable(name: "x")),
    ])
    #expect(SourceFormatter().line(error) == #"error "boom" number 42 from x"#)
}
