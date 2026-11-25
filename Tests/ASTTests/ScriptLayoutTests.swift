@testable import AST
import Extensions
import Terminology
import Testing

@Test func `script layout and declaration contracts`() throws {
    let script = Script(
        uses: [
            Use(name: "Foundation", framework: true),
            Use(scriptingAdditions: true),
            Use(name: "Kevin's Library", alias: "KevinLib"),
        ],
        properties: [Property(name: "greeting_prefix", value: StringLiteral(value: "Hello"))],
        handlers: [Handler(
            name: "run",
            body: [
                Declaration(names: ["localValue"]),
                Declaration(names: ["sharedValue"], global: true),
                AST.Comment(text: "port contract"),
                Return(value: MissingLiteral(), explicit: true),
            ],
            isRunHandler: true,
        )],
    )
    let source = try contractFormatter().script(script)
    for want in [
        #"use framework "Foundation""#,
        "use scripting additions",
        #"use KevinLib : script "Kevin's Library""#,
        #"property greeting_prefix : "Hello""#,
        "on run\n",
        "    local localValue\n",
        "    global sharedValue\n",
        "    -- port contract\n",
        "    return missing value\n",
        "end run\n",
    ] {
        #expect(source.contains(want), "source missing \(want):\n\(source)")
    }
}

@Test func `script object layout contract`() throws {
    let object = ScriptObject(
        name: "Worker",
        properties: [Property(name: "results", value: List())],
        handlers: [Handler(
            name: "collect",
            body: [Return(value: Variable(name: "results"), explicit: true)],
        )],
    )
    let want = "script Worker\n" +
        "    property results : {}\n" +
        "\n" +
        "    on collect()\n" +
        "        return results\n" +
        "    end collect\n" +
        "end script"
    let got = try contractFormatter().scriptObject(object, 0)
    try #require(got == want, "script object layout:\ngot:\n\(got)\nwant:\n\(want)")
    let scriptSource = try contractFormatter().script(Script(objects: [object]))
    try #require(scriptSource == want + "\n", "top-level script object layout:\ngot:\n\(scriptSource)\nwant:\n\(want)")
}

/**
 A property named with a word of the language is stored with a code.
 The word is printed as it is: `|name|` would be another property.
 */
@Test func `property named with a keyword`() throws {
    let script = Script(properties: [
        Property(keyword: Keyword(code: .four("ptsz")), value: NumberLiteral(integer: 3)),
        Property(keyword: Keyword(code: .four("pnam"), fallback: "name"), value: StringLiteral(value: "top")),
        Property(keyword: Keyword(code: .four("zzzz")), value: NumberLiteral(integer: 1)),
        Property(name: "name", value: NumberLiteral(integer: 2)),
    ])
    let got = try contractFormatter().script(script)
    #expect(got == "property size : 3\nproperty name : \"top\"\nproperty «class zzzz» : 1\nproperty |name| : 2\n")
}

/**
 A script keeps its members in the order of the source. Properties and
 `use` lines that follow each other are one block; every other member
 is a block of its own, with one empty line between two blocks.
 */
@Test func `members are printed in their order`() throws {
    let script = Script()
    script.properties.append(Property(name: "p", value: NumberLiteral(integer: 1)))
    script.handlers.append(Handler(name: "f"))
    script.properties.append(Property(name: "q", value: NumberLiteral(integer: 2)))
    script.properties.append(Property(name: "r", value: NumberLiteral(integer: 3)))
    script.objects.append(ScriptObject(name: "s"))
    script.handlers.append(Handler(name: "g"))
    let got = try contractFormatter().script(script)
    #expect(got == """
    property p : 1

    on f()
    end f

    property q : 2
    property r : 3

    script s
    end script

    on g()
    end g

    """)
    // Each list is a view of the members of one kind.
    #expect(script.properties.map(\.name) == ["p", "q", "r"])
    #expect(script.handlers.map(\.name) == ["f", "g"])
    #expect(script.members.count == 6)
}

/** Setting a view replaces the members of that kind, each one in its place. */
@Test func `a view of the members can be changed`() {
    let script = Script(properties: [Property(name: "a"), Property(name: "b")], handlers: [Handler(name: "f")])
    script.properties[1].name = "changed"
    #expect(script.properties.map(\.name) == ["a", "changed"])
    #expect(script.members.map { $0.property?.name ?? $0.handler?.name ?? "?" } == ["a", "changed", "f"])

    // With fewer values, the last members of the kind are removed.
    script.properties = [Property(name: "only")]
    #expect(script.members.map { $0.property?.name ?? $0.handler?.name ?? "?" } == ["only", "f"])
    // A new value goes after every member.
    script.properties.append(Property(name: "added"))
    #expect(script.members.map { $0.property?.name ?? $0.handler?.name ?? "?" } == ["only", "f", "added"])
}

/** The same order is kept inside a script object, with an empty line between handlers. */
@Test func `members of a script object`() throws {
    let object = ScriptObject(name: "s")
    object.handlers.append(Handler(name: "a"))
    object.properties.append(Property(name: "q", value: NumberLiteral(integer: 2)))
    object.objects.append(ScriptObject(name: "t"))
    object.handlers.append(Handler(name: "b"))
    object.handlers.append(Handler(name: "c"))
    let got = try contractFormatter().scriptObject(object, 0)
    #expect(got == """
    script s
        on a()
        end a

        property q : 2

        script t
        end script

        on b()
        end b

        on c()
        end c
    end script
    """)
    #expect(try contractFormatter().scriptObject(ScriptObject(name: "empty"), 1) == "    script empty\n    end script")
}

/** An implicit run handler is printed as statements at the top level. */
@Test func `implicit run handler`() throws {
    let body: [any Stmt] = [Expression(value: CommandCall(name: "beep")), Return(value: NumberLiteral(integer: 1), explicit: true)]
    let script = Script(
        properties: [Property(name: "p", value: NumberLiteral(integer: 1))],
        handlers: [Handler(name: "run", body: body, isRunHandler: true, isImplicit: true)],
    )
    #expect(try contractFormatter().script(script) == "property p : 1\n\nbeep\nreturn 1\n")
    // With no statement, nothing is printed for it.
    let empty = Script(handlers: [Handler(name: "f"), Handler(name: "run", isRunHandler: true, isImplicit: true)])
    #expect(try contractFormatter().script(empty) == "on f()\nend f\n")
}

/** A line `set name to «class code»`, to see which word the printer has for the code there. */
private func show(_ name: String, _ code: String) -> SetStmt {
    SetStmt(target: Variable(name: name), value: Keyword(code: .four(Code4(bytes: Array(code.utf8)))))
}

/**
 The compiler knows the words of an application only inside a `tell`
 block for it, and the printer follows it. `brow` is a word of Finder
 only; `home` has another word in Finder and in Standard Additions.
 */
@Test func `the words of an application are printed only inside its tell block`() throws {
    let identifier = Specifier(
        kind: .key, object: Keyword(code: .four("capp")), container: Me(), from: StringLiteral(value: "com.apple.finder"), keyName: "id",
    )
    let path = Specifier(
        kind: .index, object: Keyword(code: .four("capp")), container: Me(), from: StringLiteral(value: "/System/Library/CoreServices/Finder.app"),
    )
    let byVariable = Specifier(kind: .index, object: Keyword(code: .four("capp")), container: It(), from: Variable(name: "x"))
    let lines: [any Stmt] = [show("a", "brow"), show("b", "home")]
    let script = Script(handlers: [Handler(name: "run", body: [
        show("a", "brow"), show("b", "home"),
        Tell(target: Application(name: "Finder"), body: [
            show("a", "brow"), show("b", "home"),
            Tell(target: Application(name: "System Events"), body: lines),
            Tell(target: Me(), body: lines),
            Tell(target: Variable(name: "x"), body: lines),
            Tell(target: CurrentApplication(), body: lines),
        ]),
        Tell(target: identifier, body: lines),
        Tell(target: path, body: lines),
        Tell(target: byVariable, body: lines),
        Tell(target: Application(name: "Unknown"), body: lines),
    ] as [any Stmt], isRunHandler: true, isImplicit: true)])
    #expect(try contractFormatter().script(script) == """
    set a to «class brow»
    set b to home directory
    tell application "Finder"
        set a to Finder window
        set b to home
        tell application "System Events"
            set a to «class brow»
            set b to home directory
        end tell
        tell me
            set a to Finder window
            set b to home
        end tell
        tell x
            set a to Finder window
            set b to home
        end tell
        tell current application
            set a to «class brow»
            set b to home directory
        end tell
    end tell
    tell application id "com.apple.finder"
        set a to Finder window
        set b to home
    end tell
    tell application "/System/Library/CoreServices/Finder.app"
        set a to Finder window
        set b to home
    end tell
    tell application x
        set a to «class brow»
        set b to home directory
    end tell
    tell application "Unknown"
        set a to «class brow»
        set b to home directory
    end tell

    """)
}

/**
 A `use application` line makes the words of the application known in
 the whole script. A `tell` block for another application puts the
 words of that one first.
 */
@Test func `use application makes the words known in the whole script`() throws {
    let lines: [any Stmt] = [show("a", "brow"), show("b", "home"), show("c", "uiel")]
    let body: [any Stmt] = lines + [Tell(target: Application(name: "System Events"), body: lines), Tell(target: CurrentApplication(), body: lines)]
    let script = Script(
        uses: [Use(name: "com.apple.finder", application: true, isIdentifier: true)],
        handlers: [Handler(name: "run", body: body, isRunHandler: true, isImplicit: true)],
    )
    #expect(try contractFormatter().script(script) == """
    use application id "com.apple.finder"

    set a to Finder window
    set b to home
    set c to «class uiel»
    tell application "System Events"
        set a to Finder window
        set b to home directory
        set c to UI element
    end tell
    tell current application
        set a to Finder window
        set b to home
        set c to «class uiel»
    end tell

    """)
    // Another kind of `use` line brings no word of an application. And with a `use` line
    // the words of the scripting additions are known only with `use scripting additions`:
    // the compiler refuses `home directory` in the first of these two scripts.
    let other = Script(uses: [Use(name: "Foundation", framework: true)], handlers: [Handler(name: "run", body: lines, isRunHandler: true, isImplicit: true)])
    #expect(try contractFormatter().script(other).contains("set a to «class brow»\nset b to «class home»\n"))
    other.uses.append(Use(scriptingAdditions: true))
    #expect(try contractFormatter().script(other).contains("set a to «class brow»\nset b to home directory\n"))
    // With no `use` line at all they are known.
    other.uses = []
    #expect(try contractFormatter().script(other).contains("set a to «class brow»\nset b to home directory\n"))
    #expect(([] as [Use]).loadScriptingAdditions && !([Use(name: "2.4", version: true)] as [Use]).loadScriptingAdditions)
}

/** The three ways to name an application with a text of the script. */
@Test func `the application an expression names`() {
    func application(_ kind: SpecifierKind, _ text: String, keyName: String = "", container: any Expr = Me()) -> Specifier {
        Specifier(kind: kind, object: Keyword(code: .four("capp")), container: container, from: StringLiteral(value: text), keyName: keyName)
    }
    #expect(Application(name: "Finder").applicationName == .name("Finder"))
    #expect(application(.index, "/A/Finder.app").applicationName == .name("/A/Finder.app"))
    #expect(application(.key, "Finder", keyName: "named").applicationName == .name("Finder"))
    #expect(application(.key, "com.apple.finder", keyName: "id").applicationName == .identifier("com.apple.finder"))
    // Not `of me`, another class, another form, a text that is not in the script.
    #expect(application(.index, "Finder", container: It()).applicationName == nil)
    #expect(application(.every, "Finder").applicationName == nil)
    #expect(Specifier(kind: .index, object: Keyword(code: .four("cwin")), container: Me(), from: StringLiteral(value: "a")).applicationName == nil)
    #expect(Specifier(kind: .index, object: Keyword(code: .four("capp")), container: Me(), from: Variable(name: "x")).applicationName == nil)
    #expect(Variable(name: "x").applicationName == nil && CurrentApplication().applicationName == nil)

    #expect(Use(name: "Finder", application: true).applicationName == .name("Finder"))
    #expect(Use(name: "com.apple.finder", application: true, isIdentifier: true).applicationName == .identifier("com.apple.finder"))
    #expect(Use(name: "Foundation", framework: true).applicationName == nil)
}
