@testable import AST
import Terminology
import Testing

@Test func `formatter precedence and blocks`() {
    let script = Script(handlers: [Handler(
        name: "calculate", parameters: [Parameter(name: "x")], body: [
            SetStmt(target: Variable(name: "answer"), value: Binary(op: .multiply, left: Binary(op: .add, left: Variable(name: "x"), right: NumberLiteral(integer: 2)), right: NumberLiteral(integer: 3))),
            If(condition: Binary(op: .greater, left: Variable(name: "answer"), right: NumberLiteral(integer: 5)), then: [Return(value: Variable(name: "answer"), explicit: true)]),
        ],
    )])
    let source = format(script, terms: nil)
    for want in ["on calculate(x)", "set answer to (x + 2) * 3", "if answer > 5 then", "return answer", "end calculate"] {
        #expect(source.contains(want), "source missing \(want):\n\(source)")
    }
}

@Test func `reserved identifier`() throws {
    try #require("class".identifier == "|class|")
    try #require("items".identifier == "|items|")
    try #require("name".identifier == "|name|")
    try #require("normal_name2".identifier == "normal_name2")
}

@Test func `quote string preserves private use characters`() throws {
    // U+F8FF is a private-use character (the Apple logo in Apple fonts).
    let got = "\u{F8FF}tv \"name\"".stringLiteral
    try #require(got == "\"\u{F8FF}tv \\\"name\\\"\"")
}

@Test func `raw code decodes mac roman`() throws {
    try #require([UInt8(ascii: "c"), UInt8(ascii: "a"), UInt8(ascii: "f"), 0x8e].rawCode == "café")
    try #require([UInt8(ascii: "a"), 0, UInt8(ascii: "b"), UInt8(ascii: "c")].rawCode == "0x61006263")
}

@Test func `computed specifier selector is parenthesized`() throws {
    let script = Script(handlers: [Handler(
        name: "run",
        body: [AST.Expression(value: Specifier(
            kind: .index, object: Keyword(fallback: "menu item"),
            container: Variable(name: "menu"),
            from: Binary(op: .concatenate, left: StringLiteral(value: "Sync "), right: Variable(name: "device")),
        ))],
        isRunHandler: true,
    )])
    let source = format(script, terms: nil)
    try #require(source.contains(#"menu item ("Sync " & device) of menu"#), "source = \(source)")
}

/**
 Parentheses come from one rule: an expression has them when its level
 is lower than the level its place asks for (see `Precedence`).

 Each line here was compiled by `osacompile` in the fixture
 `operator_grouping`, and gives back the same code.
 */
@Test func `an operand has parentheses when its place asks for more`() {
    let formatter = SourceFormatter()
    let (a, b, c) = (Variable(name: "a"), Variable(name: "b"), Variable(name: "c"))
    let text = Keyword(fallback: "text")
    func op(_ kind: BinaryKind, _ left: any Expr, _ right: any Expr) -> Binary {
        Binary(op: kind, left: left, right: right)
    }
    let cases: [(node: any Expr, want: String)] = [
        // From the left: the right side asks for more.
        (op(.subtract, op(.subtract, a, b), c), "a - b - c"),
        (op(.subtract, a, op(.subtract, b, c)), "a - (b - c)"),
        (op(.or, op(.and, a, b), c), "a and b or c"),
        (op(.and, op(.or, a, b), c), "(a or b) and c"),
        // `^` is read from the right, and Apple's tools write the parentheses.
        (op(.power, a, op(.power, b, c)), "a ^ (b ^ c)"),
        (op(.power, op(.power, a, b), c), "(a ^ b) ^ c"),
        // A comparison inside another one: `a = b = c` does not compile.
        (op(.equal, op(.equal, a, b), c), "(a = b) = c"),
        (op(.equal, a, op(.equal, b, c)), "a = (b = c)"),
        (op(.less, op(.less, a, b), c), "(a < b) < c"),
        (op(.equal, a, op(.less, b, c)), "a = (b < c)"),
        (op(.equal, op(.less, a, b), c), "(a < b) = c"),
        (op(.less, op(.equal, a, b), c), "(a = b) < c"),
        (op(.less, a, op(.contains, b, c)), "a < (b contains c)"),
        (op(.contains, op(.less, a, b), c), "(a < b) contains c"),
        (op(.and, op(.equal, a, b), op(.less, b, c)), "a = b and b < c"),
        // `not` is between `and` and the comparisons.
        (op(.and, a, Unary(op: .not, value: b)), "a and not b"),
        (op(.and, Unary(op: .not, value: a), b), "not a and b"),
        (op(.equal, Unary(op: .not, value: a), b), "(not a) = b"),
        (Unary(op: .not, value: op(.equal, a, b)), "not (a = b)"),
        // `as` is between the comparisons and `&`.
        (op(.equal, a, Coerce(value: b, type: text)), "a = b as text"),
        (op(.concatenate, a, Coerce(value: b, type: text)), "a & (b as text)"),
        (Coerce(value: op(.concatenate, a, b), type: text), "a & b as text"),
        (Coerce(value: op(.equal, a, b), type: text), "(a = b) as text"),
        (Coerce(value: Coerce(value: a, type: text), type: Keyword(fallback: "list")), "a as text as list"),
        (Coerce(value: a, type: op(.concatenate, b, c)), "a as (b & c)"),
        // A minus sign holds tighter than `^`.
        (op(.power, Unary(op: .negate, value: a), b), "-a ^ b"),
        (Unary(op: .negate, value: op(.power, a, b)), "-(a ^ b)"),
    ]
    for test in cases {
        let got = formatter.expr(test.node)
        #expect(got == test.want)
    }
}

@Test func `the levels are in the order of the compiler`() {
    let order: [BinaryKind] = [.or, .and, .equal, .concatenate, .add, .multiply, .power, .of]
    for (looser, tighter) in zip(order, order.dropFirst()) {
        #expect(looser.precedence < tighter.precedence, "\(looser.rawValue) < \(tighter.rawValue)")
    }
    #expect(Precedence.and.next == .not)
    #expect(Precedence.comparison.next == .coercion)
    #expect(BinaryKind.contains.precedence == BinaryKind.less.precedence)
    #expect(Precedence.term.next == .term)
    #expect(BinaryKind.subtract.groupsFromLeft)
    #expect(!BinaryKind.power.groupsFromLeft)
    #expect(!BinaryKind.notEqual.groupsFromLeft)
}

/**
 Apple's tools write parentheses around a reference that is an operand
 of an arithmetic operator, and the printer does the same. Each line is
 in the fixture `operand_parentheses`, which `osadecompile` prints
 unchanged.
 */
@Test func `a reference in arithmetic has parentheses`() {
    let formatter = SourceFormatter()
    let (x, y) = (Variable(name: "x"), Variable(name: "y"))
    let item = Keyword(fallback: "item")
    func op(_ kind: BinaryKind, _ left: any Expr, _ right: any Expr) -> Binary {
        Binary(op: kind, left: left, right: right)
    }
    let property = Specifier(kind: .property, object: Variable(name: "p"), container: x)
    let first = Specifier(kind: .index, object: item, container: x, from: NumberLiteral(integer: 1))
    let call = HandlerCall(name: "amount")
    let mine = HandlerCall(name: "amount", target: Me())
    let cases: [(node: any Expr, want: String)] = [
        (op(.add, property, y), "(p of x) + y"),
        (op(.subtract, y, first), "y - (item 1 of x)"),
        (op(.power, HandlerCall(name: "amount", target: x), y), "(x's amount()) ^ y"),
        (op(.quotient, mine, y), "(my amount()) div y"),
        (op(.add, Application(name: "Finder"), y), #"(application "Finder") + y"#),
        // A form with no container: only an index or a key has parentheses.
        (op(.add, Specifier(kind: .index, object: item, container: It(), from: NumberLiteral(integer: 1)), y), "(item 1) + y"),
        (op(.add, Specifier(kind: .property, object: Keyword(fallback: "name"), container: It()), y), "name + y"),
        (op(.add, Specifier(kind: .every, object: item, container: It()), y), "every item + y"),
        // A call with no target: on the right of `* / div mod ^` only.
        (op(.multiply, y, call), "y * (amount())"),
        (op(.multiply, call, y), "amount() * y"),
        (op(.add, y, call), "y + amount()"),
        // The other operators take a reference bare.
        (op(.concatenate, property, y), "p of x & y"),
        (op(.equal, y, first), "y = item 1 of x"),
        (op(.concatenate, mine, y), "my amount() & y"),
        (op(.and, property, y), "p of x and y"),
        (Coerce(value: property, type: Keyword(fallback: "text")), "p of x as text"),
    ]
    for test in cases {
        let got = formatter.expr(test.node)
        #expect(got == test.want)
    }
}

/**
 `a reference to x` and `x whose test` take all that follows them. They
 are bare where a value ends, and have parentheses with an operator.
 */
@Test func `a reference and a whose clause have parentheses with an operator`() {
    let formatter = SourceFormatter()
    let (x, y) = (Variable(name: "x"), Variable(name: "y"))
    let reference = Reference(value: x)
    let every = Specifier(kind: .every, object: Keyword(fallback: "item"), container: x)
    let whose = Whose(object: every, predicate: Binary(op: .equal, left: Variable(name: "p"), right: NumberLiteral(integer: 1)))
    let text = Keyword(fallback: "text")
    #expect(formatter.expr(reference) == "a reference to x")
    #expect(formatter.expr(List(elements: [reference, y])) == "{a reference to x, y}")
    #expect(formatter.expr(Binary(op: .concatenate, left: y, right: reference)) == "y & (a reference to x)")
    #expect(formatter.expr(Binary(op: .add, left: reference, right: y)) == "(a reference to x) + y")
    #expect(formatter.expr(whose) == "every item of x whose p = 1")
    #expect(formatter.expr(Coerce(value: whose, type: text)) == "(every item of x whose p = 1) as text")
    #expect(formatter.expr(Binary(op: .concatenate, left: whose, right: y)) == "(every item of x whose p = 1) & y")
    #expect(formatter.expr(Binary(op: .power, left: y, right: whose)) == "y ^ (every item of x whose p = 1)")
    // As a container it has parentheses: without them, the text is the
    // filter on the whole reference, which is another tree.
    let name = Specifier(kind: .property, object: Keyword(fallback: "name"), container: whose)
    #expect(formatter.expr(name) == "name of (every item of x whose p = 1)")
    let first = Specifier(kind: .index, object: Keyword(fallback: "item"), container: whose, from: NumberLiteral(integer: 1))
    #expect(formatter.expr(first) == "item 1 of (every item of x whose p = 1)")
    let names = Specifier(kind: .property, object: Keyword(fallback: "name"), container: every)
    let filtered = Whose(object: names, predicate: Binary(op: .equal, left: Variable(name: "p"), right: NumberLiteral(integer: 1)))
    #expect(formatter.expr(filtered) == "name of every item of x whose p = 1")
}

/**
 A real always has a decimal point, and the form Apple's tools give it.
 The digits are the shortest ones that read back as the same number.
 */
@Test func `a real is written as Apple's tools write it`() {
    let cases: [(value: Double, want: String)] = [
        (1, "1.0"), (0, "0.0"), (100, "100.0"), (4000, "4000.0"), (9999, "9999.0"), (0.5, "0.5"), (0.01, "0.01"), (-1.5, "-1.5"),
        // From 10000 up, and under 0.01: with an exponent.
        (10000, "1.0E+4"), (12345.678, "1.2345678E+4"), (99999.5, "9.99995E+4"), (6.02e23, "6.02E+23"), (1e308, "1.0E+308"),
        (0.001, "1.0E-3"), (1e-10, "1.0E-10"), (-0.001, "-1.0E-3"),
        // Apple's tools show 3.14159265359: that is another number.
        (Double.pi, "3.141592653589793"),
    ]
    for test in cases {
        #expect(test.value.realLiteral == test.want)
        #expect(Double(test.want.replacingOccurrences(of: "E+", with: "e")) == test.value)
    }
    // Zero keeps its sign: the compiler stores `-0.0` as it is written.
    #expect((-0.0).realLiteral == "-0.0" && 0.0.realLiteral == "0.0")
    // A number that no source gives, from a damaged file: a mark, not a word that reads as a variable.
    #expect(Double.infinity.realLiteral == "«real: infinity»" && (-Double.infinity).realLiteral == "«real: minus infinity»")
    #expect(Double.nan.realLiteral == "«real: not a number»" && (-Double.nan).realLiteral == "«real: not a number»")
    let formatter = SourceFormatter()
    #expect(formatter.expr(NumberLiteral(real: 100, isReal: true)) == "100.0")
    #expect(formatter.expr(NumberLiteral(integer: 100)) == "100")
}

/**
 A name of the user that is a word of the language is written between
 bars. Before a colon, only a reserved word is.
 */
@Test func `a word of the language has bars as a name`() throws {
    let formatter = try SourceFormatter(terms: Registry.default())
    #expect(formatter.name("total") == "total")
    #expect(formatter.name("count") == "|count|")
    #expect(formatter.name("Count") == "|Count|")
    #expect(formatter.name("error") == "|error|")
    #expect(formatter.name("my key") == "|my key|")
    // Without terminology, only the reserved words are known.
    #expect(SourceFormatter().name("count") == "count")

    let call = HandlerCall(name: "count", target: Variable(name: "a"))
    #expect(formatter.expr(call) == "a's |count|()")
    let record = Record(fields: [RecordField(label: StringLiteral(value: "name"), value: NumberLiteral(integer: 1))])
    #expect(formatter.expr(record) == "{|name|:1}")
    let colon = Handler(name: "tableView_row_error_", parameters: [Parameter(name: "t"), Parameter(name: "r"), Parameter(name: "e")])
    #expect(formatter.handler(colon, 0) == "on tableView:t row:r |error|:e\nend tableView:row:|error|:")
}

/**
 `start with`, `contained by`, `out of` are keywords of two words. A
 name that is their first word has bars only in front of the second
 word, and everywhere when it has a capital letter.
 */
@Test func `a name has bars in front of the word it would join with`() throws {
    let formatter = try SourceFormatter(terms: Registry.default())
    #expect(formatter.name("start") == "start")
    #expect(formatter.name("Start") == "|Start|")
    #expect(formatter.barring.name("start") == "|start|")
    #expect(formatter.before("display dialog start", "with icon 1", barred: "display dialog |start|") == "display dialog |start|")
    #expect(formatter.before("from 1 to contained", "by", barred: "from 1 to |contained|") == "from 1 to |contained|")
    // Not in front of another word, and not a name that only ends like one.
    #expect(formatter.before("display dialog start", "buttons {1}", barred: "display dialog |start|") == "display dialog start")
    #expect(formatter.before("from 1 to start", "by", barred: "from 1 to |start|") == "from 1 to start")
    #expect(formatter.before("display dialog restart", "with icon 1", barred: "display dialog restart") == "display dialog restart")
    #expect(formatter.before("display dialog |start|", "with icon 1", barred: "display dialog |start|") == "display dialog |start|")
    // The last word of a term is not a name: the printer leaves it as it is, with bars or not.
    #expect(formatter.before("arrow at start", "with x", barred: "arrow at start") == "arrow at start")
    let parts = ["display dialog", "start", "with icon 1"]
    #expect(formatter.parts(parts, barred: ["display dialog", "|start|", "with icon 1"]) == "display dialog |start| with icon 1")

    // The places where a word follows a name.
    let one = NumberLiteral(integer: 1)
    let y = Variable(name: "y")
    #expect(formatter.expr(Specifier(kind: .property, object: Variable(name: "out"), container: y)) == "|out| of y")
    #expect(formatter.expr(Specifier(kind: .index, object: Keyword(code: .four("cobj")), container: y, from: Variable(name: "instead"))) == "item |instead| of y")
    #expect(formatter.expr(Specifier(kind: .property, object: Variable(name: "out"))) == "out")
    let loop = Repeat(kind: .range, variable: "apart", from: one, to: Variable(name: "contained"), by: NumberLiteral(integer: 2))
    #expect(formatter.repeatHeader(loop) == "repeat with |apart| from 1 to |contained| by 2")
    let plain = Repeat(kind: .range, variable: "apart", from: Variable(name: "contained"), to: one, by: one)
    #expect(formatter.repeatHeader(plain) == "repeat with |apart| from contained to 1")
    let call = LabeledCall(name: "out", direct: Variable(name: "info"), arguments: [LabeledArgument(label: .code("for "), value: one)])
    #expect(formatter.labeledCall(call) == "|out| of |info| for 1")
    let header = Handler(name: "contained", parameters: [Parameter(name: "comes", code: "by  "), Parameter(name: "x", code: "from")])
    #expect(formatter.handler(header, 0) == "on |contained| by comes from x\nend |contained|")
    let direct = Handler(name: "lab", parameters: [Parameter(name: "contained"), Parameter(name: "y", code: "by  ")])
    #expect(formatter.handler(direct, 0) == "on lab of |contained| by y\nend lab")
    let failed = Try(errorName: "aside", parameters: [ErrorParameter(.from, Variable(name: "f"))])
    #expect(formatter.tryBlock(failed, 0) == "try\non error |aside| from f\nend try")
}

/** Before a colon, a word of the language needs bars like anywhere else. */
@Test func `a label that is a word of the language has bars before a colon`() throws {
    let formatter = try SourceFormatter(terms: Registry.default())
    let one = NumberLiteral(integer: 1)
    let call = HandlerCall(name: "foo_data_count_forKey_", target: Variable(name: "x"), arguments: [one, one, one, one])
    #expect(formatter.expr(call, .statement) == "x's foo:1 |data|:1 |count|:1 forKey:1")
    let opened = Handler(name: "open_by_", parameters: [Parameter(name: "a"), Parameter(name: "b")])
    #expect(formatter.handler(opened, 0) == "on |open|:a |by|:b\nend |open|:|by|:")
}

/**
 A word of an application has bars only inside the `tell` block of
 that application. With a capital letter, the name with bars and the
 name without are two variables: such a name has bars everywhere.
 */
@Test func `a name with a capital letter that has bars in a tell block has bars everywhere`() throws {
    let formatter = try SourceFormatter(terms: Registry.default())
    func script(_ name: String) -> Script {
        Script(handlers: [Handler(name: "f", parameters: [Parameter(name: name)], body: [
            Tell(target: Application(name: "Mail"), body: [SetStmt(target: Variable(name: "x"), value: Variable(name: name))]),
            Return(value: Variable(name: name), explicit: true),
        ] as [any Stmt])])
    }
    #expect(formatter.script(script("Subject")) == """
    on f(|Subject|)
        tell application "Mail"
            set x to |Subject|
        end tell
        return |Subject|
    end f

    """)
    #expect(formatter.script(script("subject")) == """
    on f(subject)
        tell application "Mail"
            set x to |subject|
        end tell
        return subject
    end f

    """)
}

/** `considering` and `ignoring` blocks, with the words joined as the language does. */
@Test func `considering and ignoring blocks`() {
    let formatter = SourceFormatter()
    #expect(formatter.stmt(Considering(options: ["case", "diacriticals", "punctuation"]), 0)
        == "considering case, diacriticals and punctuation\nend considering")
    #expect(formatter.stmt(Considering(ignored: ["white space", "hyphens"]), 0) == "ignoring white space and hyphens\nend ignoring")
    #expect(formatter.stmt(Considering(options: ["case"], ignored: ["white space"]), 0)
        == "considering case but ignoring white space\nend considering")
}

/**
 What Apple's tools write around a call with colons: each argument that
 is not one word is in parentheses, and in a `repeat with` loop the
 whole call is.
 */
@Test func `a call with colons has Apple's parentheses`() {
    let formatter = SourceFormatter()
    let (a, x) = (Variable(name: "a"), Variable(name: "x"))
    let sum = Binary(op: .add, left: x, right: NumberLiteral(integer: 1))
    let name = Specifier(kind: .property, object: Keyword(fallback: "name"), container: x)
    let call = HandlerCall(name: "insertObject_atIndex_", target: a, arguments: [name, sum])
    #expect(formatter.expr(call, .statement) == "a's insertObject:(name of x) atIndex:(x + 1)")
    #expect(formatter.expr(HandlerCall(name: "add_", target: a, arguments: [MissingLiteral()]), .statement) == "a's add:(missing value)")
    #expect(formatter.expr(HandlerCall(name: "add_", target: a, arguments: [List(elements: [x])]), .statement) == "a's add:{x}")

    let plain = HandlerCall(name: "add_", target: a, arguments: [x])
    func loop(_ kind: RepeatKind) -> String {
        formatter.stmt(Repeat(kind: kind, variable: "i", collection: x, from: x, to: x, body: [Expression(value: plain)]), 0)
    }
    #expect(loop(.in) == "repeat with i in x\n    (a's add:x)\nend repeat")
    #expect(loop(.range) == "repeat with i from x to x\n    (a's add:x)\nend repeat")
    #expect(loop(.forever) == "repeat\n    a's add:x\nend repeat")
}

/** The other forms found with the probes. */
@Test func `forms found with the probes`() {
    let formatter = SourceFormatter()
    let (x, i, j) = (Variable(name: "x"), Variable(name: "i"), Variable(name: "j"))
    let item = Keyword(fallback: "item")
    func plus(_ left: any Expr, _ right: Int64) -> Binary {
        Binary(op: .add, left: left, right: NumberLiteral(integer: right))
    }
    // The ends of a range are one term each.
    let range = Specifier(kind: .range, object: item, container: x, from: plus(i, 1), to: Specifier(kind: .property, object: Keyword(fallback: "length"), container: j))
    #expect(formatter.expr(range) == "item (i + 1) thru (length of j) of x")
    // Ends that are objects of the container: `from … to …`.
    let word = Keyword(fallback: "word")
    func part(_ number: Int64) -> Specifier {
        Specifier(kind: .index, object: word, container: x, from: NumberLiteral(integer: number))
    }
    #expect(formatter.expr(Specifier(kind: .range, object: Keyword(fallback: "text"), container: x, from: part(1), to: part(2)))
        == "text from word 1 to word 2 of x")
    // Relative forms.
    let window = Keyword(fallback: "window")
    let first = Specifier(kind: .index, object: window, container: It(), from: NumberLiteral(integer: 1))
    #expect(formatter.expr(Specifier(kind: .after, object: window, container: first)) == "window after window 1")
    #expect(formatter.expr(Specifier(kind: .before, object: window, container: first)) == "window before window 1")
    // `its n` for a word of the user; a term has no `of it`.
    #expect(formatter.expr(Specifier(kind: .property, object: Variable(name: "n"), container: It())) == "its n")
    #expect(formatter.expr(Specifier(kind: .property, object: Keyword(fallback: "name"), container: It())) == "name")
    // A power on the right of `*`.
    let power = Binary(op: .power, left: i, right: j)
    #expect(formatter.expr(Binary(op: .multiply, left: x, right: power)) == "x * (i ^ j)")
    #expect(formatter.expr(Binary(op: .multiply, left: power, right: x)) == "i ^ j * x")
    #expect(formatter.expr(Binary(op: .add, left: x, right: power)) == "x + i ^ j")
    // Flags that follow each other; a script object with no name; `get`.
    let flags = CommandCall(name: "choose", arguments: [
        FlagArgument(name: "a", enabled: true), FlagArgument(name: "b", enabled: true), FlagArgument(name: "c", enabled: false),
    ])
    #expect(formatter.expr(flags, .statement) == "choose with a and b without c")
    #expect(formatter.scriptObject(ScriptObject(name: ""), 0) == "script\nend script")
    #expect(formatter.stmt(SetStmt(target: x, value: GetExpr(value: i)), 0) == "set x to get i")
    #expect(formatter.expr(plus(GetExpr(value: i), 1)) == "(get i) + 1")
    #expect(formatter.use(Use(name: "2.4", version: true)) == #"use AppleScript version "2.4""#)
    #expect(formatter.use(Use(name: "Finder", application: true)) == #"use application "Finder""#)
    #expect(formatter.use(Use(name: "com.apple.finder", application: true, isIdentifier: true)) == #"use application id "com.apple.finder""#)
}

/** A `global` line outside the handlers is printed with the `use` lines and the properties. */
@Test func `a global line outside the handlers is printed`() {
    let script = Script(properties: [Property(name: "p", value: NumberLiteral(integer: 1))])
    script.members.insert(.globals(Declaration(names: ["g", "count"], global: true)), at: 0)
    #expect(format(script, terms: nil) == "global g, count\nproperty p : 1\n")
    let names = Specifier(kind: .property, object: List(elements: [
        Specifier(kind: .property, object: Keyword(fallback: "name")), Specifier(kind: .index, object: Keyword(fallback: "item"), from: NumberLiteral(integer: 1)),
    ]), container: Variable(name: "x"))
    #expect(SourceFormatter().expr(names) == "{name, item 1} of x")
}

/**
 A handler that answers a command of an application is printed inside
 `using terms from`, unless the source named the event by its code.
 */
@Test func `a handler that answers a command of an application`() throws {
    let formatter = try SourceFormatter(terms: Registry.default())
    func rule(raw: Bool) -> Handler {
        let handler = Handler(name: "rule", eventCode: "emalcpma", parameters: [Parameter(name: "m"), Parameter(name: "r", code: "pmar")])
        handler.isRawEvent = raw
        return handler
    }
    #expect(formatter.members([.handler(rule(raw: false))], 0) == ["""
    using terms from application "Mail"
        on perform mail action with messages m for rule r
        end perform mail action with messages
    end using terms from
    """])
    #expect(formatter.members([.handler(rule(raw: true))], 0) == ["on «event emalcpma» m given «class pmar»:r\nend «event emalcpma»"])
    // A command of Standard Additions needs no block.
    let dialog = Handler(name: "dialog", eventCode: "sysodlog", parameters: [Parameter(name: "m")])
    #expect(formatter.members([.handler(dialog)], 0) == ["on display dialog m\nend display dialog"])

    // A place to put something has no class to name: `at after file 1`.
    let file = Specifier(kind: .index, object: Keyword(fallback: "file"), container: It(), from: NumberLiteral(integer: 1))
    #expect(formatter.expr(Specifier(kind: .after, object: Keyword(code: .four("insl")), container: file)) == "after file 1")
    #expect(formatter.expr(Specifier(kind: .before, object: Keyword(fallback: "window"), container: file)) == "window before file 1")

    // A name that is a word of the told application has bars inside the block.
    let inside = Tell(target: Application(name: "Safari"), body: [SetStmt(target: Variable(name: "tabs"), value: NumberLiteral(integer: 1))])
    #expect(formatter.stmt(inside, 0) == "tell application \"Safari\"\n    set |tabs| to 1\nend tell")
    #expect(formatter.stmt(SetStmt(target: Variable(name: "tabs"), value: NumberLiteral(integer: 1)), 0) == "set tabs to 1")
}

/** Between bars, a bar and a backslash are written after a backslash. */
@Test func `a name between bars`() {
    #expect("a b".identifier == "|a b|")
    #expect("a|b".identifier == #"|a\|b|"#)
    #expect(#"a\b"#.identifier == #"|a\\b|"#)
    #expect("plain".identifier == "plain")
}
