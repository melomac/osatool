@testable import AST
import Extensions
import Terminology
import Testing

@Test func `word lists`() {
    #expect([String]().wordList == "")
    #expect(["a"].wordList == "a")
    #expect(["a", "b"].wordList == "a and b")
    #expect(["a", "b", "c"].wordList == "a, b and c")
}

@Test func `literal record and specifier contracts`() throws {
    let f = try contractFormatter()
    let date = f.expr(DateLiteral(value: "1 January 2025"))
    #expect(date == #"date "1 January 2025""#, "date = \(date)")
    let record = Record(fields: [
        RecordField(label: StringLiteral(value: "safe_name"), value: NumberLiteral(integer: 1)),
        RecordField(label: StringLiteral(value: "not valid"), value: NumberLiteral(integer: 2)),
    ])
    let recordText = f.expr(record)
    #expect(recordText == "{safe_name:1, |not valid|:2}", "record = \(recordText)")
    let container = Variable(name: "values")
    let cases: [(node: any Expr, want: String)] = [
        (Specifier(kind: .index, object: Keyword(fallback: "item"), container: container, from: NumberLiteral(integer: 2)), "item 2 of values"),
        (Specifier(kind: .key, object: Keyword(fallback: "item"), container: Me(), from: NumberLiteral(integer: 7), keyName: "id"), "item id 7 of me"),
        (Specifier(kind: .key, object: Keyword(code: .four("cha ")), container: Me(), from: NumberLiteral(integer: 65), keyName: "id"), "character id 65"),
        (Specifier(kind: .index, object: Keyword(fallback: "item"), container: Me(), from: NumberLiteral(integer: 1)), "item 1 of me"),
        (Specifier(kind: .index, object: Keyword(fallback: "item"), container: It(), from: NumberLiteral(integer: 1)), "item 1"),
        (Specifier(kind: .property, object: Keyword(fallback: "name"), container: Me()), "name of me"),
        (Specifier(kind: .property, object: Keyword(fallback: "name"), container: It()), "name"),
        (Specifier(kind: .every, object: Keyword(fallback: "item"), container: It()), "every item"),
        (Specifier(kind: .range, object: Keyword(code: .four("cobj")), container: container, from: NumberLiteral(integer: 2), to: NumberLiteral(integer: 4)), "items 2 thru 4 of values"),
        (Specifier(kind: .key, object: Keyword(fallback: "item"), container: container, from: StringLiteral(value: "target"), keyName: "named"), #"item named "target" of values"#),
        (Specifier(kind: .key, object: Keyword(code: .four("cha ")), container: It(), from: NumberLiteral(integer: 65), keyName: "id"), "character id 65 of it"),
        (Specifier(kind: .property, object: Keyword(fallback: "name"), container: container), "name of values"),
        (Specifier(kind: .every, object: Keyword(fallback: "item"), container: container), "every item of values"),
        (Specifier(kind: .middle, object: Keyword(fallback: "item"), container: container), "middle item of values"),
        (Specifier(kind: .some, object: Keyword(fallback: "item"), container: container), "some item of values"),
        (Specifier(kind: .beginning, container: container), "beginning of values"),
        (Specifier(kind: .end, container: container), "end of values"),
        (Specifier(kind: .range, object: Keyword(fallback: "text"), container: Variable(name: "ret"), from: NumberLiteral(integer: 1), to: NumberLiteral(integer: -2)), "text 1 thru -2 of ret"),
    ]
    for test in cases {
        let got = f.expr(test.node)
        #expect(got == test.want, "\(test.node.nodeName) = \(got), want \(test.want)")
    }
    let whose = Whose(
        object: Specifier(kind: .property, object: Keyword(fallback: "name"), container: Specifier(
            kind: .index, object: Variable(name: "process"), container: It(), from: NumberLiteral(integer: 1),
        )),
        predicate: Binary(op: .equal, left: Keyword(fallback: "frontmost"), right: BooleanLiteral(value: true)),
    )
    let whoseText = f.expr(whose)
    #expect(whoseText == "name of process 1 whose frontmost = true", "whose = \(whoseText)")
}

@Test func `every expression operator`() throws {
    let f = try contractFormatter()
    let left = Variable(name: "a")
    let right = Variable(name: "b")
    let cases: [(op: BinaryKind, want: String)] = [
        (.equal, "a = b"), (.notEqual, "a ≠ b"),
        (.greater, "a > b"), (.greaterEqual, "a ≥ b"),
        (.less, "a < b"), (.lessEqual, "a ≤ b"),
        (.startsWith, "a starts with b"), (.endsWith, "a ends with b"),
        (.contains, "a contains b"), (.and, "a and b"), (.or, "a or b"),
        (.add, "a + b"), (.subtract, "a - b"), (.multiply, "a * b"),
        (.divide, "a / b"), (.quotient, "a div b"), (.remainder, "a mod b"),
        (.power, "a ^ b"), (.concatenate, "a & b"), (.of, "a of b"),
    ]
    for test in cases {
        let got = f.expr(Binary(op: test.op, left: left, right: right))
        #expect(got == test.want, "\(test.op.rawValue) = \(got), want \(test.want)")
    }
    let negate = f.expr(Unary(op: .negate, value: NumberLiteral(integer: 2)))
    #expect(negate == "-2", "negate = \(negate)")
    let not = f.expr(Unary(op: .not, value: BooleanLiteral(value: true)))
    #expect(not == "not true", "not = \(not)")
    let coerce = f.expr(Coerce(value: left, type: Keyword(fallback: "text")))
    #expect(coerce == "a as text", "coerce = \(coerce)")

    // Parentheses are printed only where the source needs them.
    let sum = Binary(op: .add, left: left, right: right)
    let item = Specifier(kind: .index, object: Keyword(fallback: "item"), container: left, from: NumberLiteral(integer: 3))
    let cases2: [(node: any Expr, want: String)] = [
        (Unary(op: .negate, value: left), "-a"),
        // A minus sign in front of anything else does not compile.
        (Unary(op: .negate, value: item), "-(item 3 of a)"),
        (Unary(op: .negate, value: HandlerCall(name: "f")), "-(f())"),
        (Unary(op: .negate, value: sum), "-(a + b)"),
        (Unary(op: .not, value: left), "not a"),
        (Unary(op: .not, value: Binary(op: .equal, left: left, right: right)), "not (a = b)"),
        // `not` binds less than a comparison.
        (Binary(op: .equal, left: Unary(op: .not, value: left), right: right), "(not a) = b"),
        (Binary(op: .and, left: Unary(op: .not, value: left), right: right), "not a and b"),
        // `as` binds less than `&`.
        (Binary(op: .concatenate, left: left, right: Coerce(value: right, type: Keyword(fallback: "text"))), "a & (b as text)"),
        (Coerce(value: Binary(op: .concatenate, left: left, right: right), type: Keyword(fallback: "text")), "a & b as text"),
        (Binary(op: .equal, left: Coerce(value: left, type: Keyword(fallback: "text")), right: right), "a as text = b"),
        (List(elements: [Coerce(value: left, type: Keyword(fallback: "text"))]), "{a as text}"),
        // A call to a handler of another object is one side of an operation.
        (Binary(op: .add, left: HandlerCall(name: "f", target: left), right: HandlerCall(name: "g")), "(a's f()) + g()"),
    ]
    for test in cases2 {
        let got = f.expr(test.node)
        #expect(got == test.want, "got \(got), want \(test.want)")
    }
}

/**
 A stored constant is one number. A number that fits in four bytes is a
 four-character code; a larger one takes the bytes it needs.
 */
@Test func `keyword codes from packed constants`() {
    #expect(KeywordCode(packed: 0x706e_616d) == .four("pnam"))
    #expect(KeywordCode(packed: 0) == .four(Code4()))
    #expect(KeywordCode(packed: 0x7361_766f_7965_7320) == .eight("savoyes "))
    #expect(KeywordCode(packed: 0x41_4243_4445) == .other([0x41, 0x42, 0x43, 0x44, 0x45]))
    #expect(KeywordCode(packed: 0x0041_4243_4445_4647) == .other([0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47]))
    // Eight bytes whose first four are zero cannot be told from four bytes.
    #expect(KeywordCode(packed: 0x0000_0000_7965_7320) == .four("yes "))
}

@Test func `keyword codes from bytes`() {
    #expect(KeywordCode(bytes: []) == nil)
    #expect(KeywordCode(bytes: Array("pnam".utf8)) == .four("pnam"))
    #expect(KeywordCode(bytes: Array("savoyes ".utf8)) == .eight("savoyes "))
    #expect(KeywordCode(bytes: [1, 2, 3]) == .other([1, 2, 3]))
    let samples: [[UInt8]] = [Array("pnam".utf8), Array("savoyes ".utf8), [1, 2, 3, 4, 5]]
    for bytes in samples {
        #expect(KeywordCode(bytes: bytes)?.bytes == bytes)
    }
}

/** Each kind of code has its own raw form when the terminology has no word for it. */
@Test func `keyword printing by kind of code`() {
    let formatter = SourceFormatter(terms: nil)
    #expect(formatter.expr(Keyword(code: .four("zzzz"))) == "«class zzzz»")
    #expect(formatter.expr(Keyword(code: .eight("testABCD"))) == "«constant testABCD»")
    #expect(formatter.expr(Keyword(code: .other([0x41, 0x42, 0x43, 0x44, 0x45]))) == "«constant 4142434445»")
    #expect(formatter.expr(Keyword(code: .four("zzzz"), fallback: "word")) == "word")
    #expect(formatter.expr(Keyword()) == "«constant »")
}

/**
 A class and an enumerator are two kinds of value, and each has its own
 words. `osacompile` makes «class msng» from `missing value`, not the
 enumerator, and `osadecompile` prints the three raw forms here as they
 are.
 */
@Test func `a class word is not printed for an enumerator`() throws {
    let formatter = try contractFormatter()
    // An enumerator, with its group or with any group.
    #expect(formatter.expr(Keyword(code: .eight("savoyes "))) == "yes")
    #expect(formatter.expr(Keyword(code: .eight("****yes "))) == "yes")
    #expect(formatter.expr(Keyword(code: .eight("conscase"))) == "case")
    // A class or a property.
    #expect(formatter.expr(Keyword(code: .four("PICT"))) == "picture")
    #expect(formatter.expr(Keyword(code: .four("msng"))) == "missing value")
    // The letters of a class in an enumerator, and the other way round.
    #expect(formatter.expr(Keyword(code: .eight("****msng"))) == "«constant ****msng»")
    #expect(formatter.expr(Keyword(code: .four("Kclk"))) == "«class Kclk»")
    #expect(formatter.expr(Keyword(code: .four("yes "))) == "«class yes »")
}

/** `application "X" is running` is stored as a comparison of the property with `true`. */
@Test func `is running`() throws {
    let f = try contractFormatter()
    let running = Specifier(kind: .property, object: Keyword(code: .four("prun"), fallback: "running"), container: Application(name: "Finder"))
    #expect(f.expr(Binary(op: .equal, left: running, right: BooleanLiteral(value: true))) == #"application "Finder" is running"#)
    #expect(f.expr(Binary(op: .notEqual, left: running, right: BooleanLiteral(value: true))) == #"application "Finder" is not running"#)
    // Another value, or another owner, is an ordinary comparison.
    #expect(f.expr(Binary(op: .equal, left: running, right: BooleanLiteral(value: false))) == #"running of application "Finder" = false"#)
    let other = Specifier(kind: .property, object: Keyword(code: .four("prun"), fallback: "running"), container: Variable(name: "x"))
    #expect(f.expr(Binary(op: .equal, left: other, right: BooleanLiteral(value: true))) == "running of x = true")
}

/**
 `text of x` is `every text of x` for the compiler, because `text` is
 its own plural. The short form is printed. Without a container the
 word alone is the class, so `every` stays.
 */
@Test func `a class that is its own plural is printed without every`() throws {
    let formatter = try contractFormatter()
    func every(_ code: Code4, _ container: any Expr?) -> Specifier {
        Specifier(kind: .every, object: Keyword(code: .four(code)), container: container)
    }
    let x = Variable(name: "x")
    #expect(formatter.expr(every("ctxt", x)) == "text of x")
    #expect(formatter.expr(every("STXT", x)) == "styled text of x")
    #expect(formatter.expr(every("ctxt", every("docu", x))) == "text of every document of x")
    // Not its own plural.
    #expect(formatter.expr(every("utxt", x)) == "every Unicode text of x")
    #expect(formatter.expr(every("cobj", x)) == "every item of x")
    // No container to name.
    #expect(formatter.expr(every("ctxt", It())) == "every text")
    #expect(formatter.expr(every("ctxt", nil)) == "every text")
    // A word of the user is not a class.
    #expect(formatter.expr(Specifier(kind: .every, object: Keyword(fallback: "text"), container: x)) == "every text of x")
    // Without terminology there is no word at all.
    #expect(SourceFormatter().expr(every("ctxt", x)) == "every «class ctxt» of x")

    // The property with that code cannot be written with the word: the
    // compiler would read `text of x` as every text of x.
    func property(_ code: Code4, _ container: any Expr?) -> Specifier {
        Specifier(kind: .property, object: Keyword(code: .four(code)), container: container)
    }
    #expect(formatter.expr(property("ctxt", x)) == "«property ctxt» of x")
    #expect(formatter.expr(property("ctxt", It())) == "«property ctxt»")
    #expect(formatter.expr(property("utxt", x)) == "Unicode text of x")
    #expect(formatter.expr(property("pnam", x)) == "name of x")
}

/**
 What selects one object is one term. A reference there has
 parentheses: `of` would take it apart. `osacompile` makes another
 script from `item item i of order of names`.
 */
@Test func `a selector that is not one term has parentheses`() throws {
    let formatter = try contractFormatter()
    let (x, i, order) = (Variable(name: "x"), Variable(name: "i"), Variable(name: "order"))
    func item(_ selector: any Expr, of container: any Expr = Variable(name: "x")) -> Specifier {
        Specifier(kind: .index, object: Keyword(code: .four("cobj")), container: container, from: selector)
    }
    #expect(formatter.expr(item(NumberLiteral(integer: 3))) == "item 3 of x")
    #expect(formatter.expr(item(NumberLiteral(integer: -1))) == "item -1 of x")
    #expect(formatter.expr(item(Unary(op: .negate, value: i))) == "item -i of x")
    #expect(formatter.expr(item(i)) == "item i of x")
    #expect(formatter.expr(item(StringLiteral(value: "a"))) == #"item "a" of x"#)
    #expect(formatter.expr(item(item(i, of: order))) == "item (item i of order) of x")
    #expect(formatter.expr(item(Binary(op: .add, left: i, right: NumberLiteral(integer: 1)))) == "item (i + 1) of x")
    #expect(formatter.expr(item(HandlerCall(name: "pick", target: Me(), arguments: [x]))) == "item (my pick(x)) of x")
    let length = Specifier(kind: .property, object: Keyword(code: .four("leng")), container: x)
    #expect(formatter.expr(item(length)) == "item (length of x) of x")
    // A property of the target, written as its word alone, is one term.
    let own = Specifier(kind: .property, object: Keyword(code: .four("leng")), container: It())
    #expect(formatter.expr(item(own)) == "item length of x")
    // The same for a key.
    let key = Specifier(kind: .key, object: Keyword(code: .four("cwin")), container: x, from: Specifier(kind: .property, object: Keyword(code: .four("ID  ")), container: i), keyName: "id")
    #expect(formatter.expr(key) == "window id (id of i) of x")
}

/**
 The opposite of a negative number is written with parentheses: two
 minus signs start a comment.
 */
@Test func `two minus signs are never printed`() {
    let formatter = SourceFormatter()
    #expect(formatter.expr(Unary(op: .negate, value: NumberLiteral(integer: -5))) == "-(-5)")
    #expect(formatter.expr(Unary(op: .negate, value: NumberLiteral(real: -0.5, isReal: true))) == "-(-0.5)")
    #expect(formatter.expr(Unary(op: .negate, value: NumberLiteral(integer: 5))) == "-5")
    #expect(formatter.expr(Unary(op: .negate, value: Unary(op: .negate, value: Variable(name: "x")))) == "-(-x)")
}

/** One pair of parentheses around all the rest, not one at each end. */
@Test func `a text in parentheses`() {
    for text in ["(a)", "(a + (b))", #"(a & ")")"#, "(|a)b|)", #"("\"(" & x)"#] {
        #expect(text.isParenthesized, "\(text)")
    }
    for text in ["a", "(a) + (b)", "(a)'s b()", "((a)'s b)'s c()", #"(a) & ")""#, "(a", "", "()x"] {
        #expect(!text.isParenthesized, "\(text)")
    }
    // An argument that only starts and ends with a parenthesis gets its own.
    let formatter = SourceFormatter()
    let inner = HandlerCall(name: "f", target: Binary(op: .add, left: Variable(name: "a"), right: Variable(name: "b")), arguments: [])
    #expect(formatter.term(inner) == "((a + b)'s f())")
}
