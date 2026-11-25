import Extensions
import Terminology

/**
 The syntax tree of a decompiled script.

 ```
 Script
 ├─ uses         use framework "Foundation"
 ├─ properties   property x : 1
 ├─ objects      script Helper … end script
 └─ handlers     on run … end run
        └─ body: [Stmt]
               └─ expressions: Expr
 ```

 Nodes are classes: the decompiler and the passes change them in place,
 and the decompiler compares nodes by identity (`===`).

 A property typed `(any Expr)?` can be `nil`. The formatter prints a
 missing expression as `missing value`.

 The `set` statement is named `SetStmt`, so it does not hide Swift's `Set`.
 */
package protocol Node: AnyObject {}

/** A node that produces a value. */
package protocol Expr: Node {
    /**
     Replaces each expression directly inside this one with
     `rewrite(child)`, in order. A node without children does nothing.
     */
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?)
}

package extension Expr {
    func rewriteChildren(_: (any Expr?) -> (any Expr)?) {}
}

/** A node that is one statement line or one block. */
package protocol Stmt: Node {
    /**
     Replaces each expression the statement holds directly with
     `rewrite(expression)`, in order.
     */
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?)

    /** The lists of statements inside this one: a body, `else`, `on error`. */
    var bodies: [[any Stmt]] { get }
}

package extension Stmt {
    func rewriteExpressions(_: (any Expr?) -> (any Expr)?) {}

    var bodies: [[any Stmt]] {
        []
    }
}

/**
 One declaration of a script, or of a script object.

 A script keeps its members in one list, in the order of the source:

 ```
 global g                .globals
 property p : 1          .property
 on f() … end f          .handler
 script s … end script   .object
 ```

 `properties`, `handlers` and the other lists of a script are views of
 that list: they give the members of one kind, in order.
 */
package enum Member {
    case use(Use)
    /** A `global` line outside every handler. */
    case globals(Declaration)
    case property(Property)
    case object(ScriptObject)
    case handler(Handler)

    package var use: Use? {
        if case let .use(value) = self {
            value
        } else {
            nil
        }
    }

    package var property: Property? {
        if case let .property(value) = self {
            value
        } else {
            nil
        }
    }

    package var object: ScriptObject? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }

    package var handler: Handler? {
        if case let .handler(value) = self {
            value
        } else {
            nil
        }
    }
}

package extension [Member] {
    /**
     Sets the members of one kind to `values`. Each value takes the
     place of the old member of that kind with the same rank; values
     that are left go to the end of the list. So adding one value to a
     view adds a member after all the others.

     - `kind`: reads a member of the kind (`\.property`).
     - `make`: builds a member of the kind (`Member.property`).
     */
    mutating func replace<Value>(_ values: [Value], _ kind: (Member) -> Value?, _ make: (Value) -> Member) {
        var left = values[...]
        var result: [Member] = []
        for member in self {
            if kind(member) == nil {
                result.append(member)
            } else if let value = left.popFirst() {
                result.append(make(value))
            }
        }
        result.append(contentsOf: left.map(make))
        self = result
    }
}

package final class Script: Node {
    /** The declarations of the script, in the order of the source. */
    package var members: [Member]

    package var uses: [Use] {
        get { self.members.compactMap(\.use) }
        set { self.members.replace(newValue, \.use, Member.use) }
    }

    package var properties: [Property] {
        get { self.members.compactMap(\.property) }
        set { self.members.replace(newValue, \.property, Member.property) }
    }

    package var objects: [ScriptObject] {
        get { self.members.compactMap(\.object) }
        set { self.members.replace(newValue, \.object, Member.object) }
    }

    package var handlers: [Handler] {
        get { self.members.compactMap(\.handler) }
        set { self.members.replace(newValue, \.handler, Member.handler) }
    }

    package init(uses: [Use] = [], properties: [Property] = [], objects: [ScriptObject] = [], handlers: [Handler] = []) {
        self.members = uses.map(Member.use) + properties.map(Member.property) + objects.map(Member.object) + handlers.map(Member.handler)
    }
}

/**
 A `use` line:

 ```
 use AppleScript version "2.4"       version, with the number in `name`
 use scripting additions             scriptingAdditions
 use framework "Foundation"          framework
 use application "Finder"            application
 use application id "com.apple.x"    application, isIdentifier
 use tools : script "Tools"          a script library, with its alias
 ```
 */
package struct Use {
    package var name: String
    package var alias: String
    package var framework: Bool
    package var scriptingAdditions: Bool
    package var application: Bool
    /** True when `name` is the identifier of the application, not its name. */
    package var isIdentifier: Bool
    package var version: Bool

    package init(
        name: String = "", alias: String = "", framework: Bool = false, scriptingAdditions: Bool = false,
        application: Bool = false, isIdentifier: Bool = false, version: Bool = false,
    ) {
        self.name = name
        self.alias = alias
        self.framework = framework
        self.scriptingAdditions = scriptingAdditions
        self.application = application
        self.isIdentifier = isIdentifier
        self.version = version
    }

    /** The application of a `use application` line, or `nil` for another kind of line. */
    package var applicationName: ApplicationName? {
        guard self.application else {
            return nil
        }
        return self.isIdentifier ? .identifier(self.name) : .name(self.name)
    }
}

package extension [Use] {
    /**
     True when the script loads the scripting additions: it has no
     `use` line, or one of them is `use scripting additions`. With any
     other `use` line the compiler does not know their words.
     */
    var loadScriptingAdditions: Bool {
        self.isEmpty || self.contains { $0.scriptingAdditions }
    }
}

/**
 A property of a script or of a script object.

 The name is a user word (`name`), or a word of the language or of an
 application (`keyword`), which the compiler stores as a code:

 ```
 property label : "x"        name "label"
 property size : 3           keyword with the code 'ptsz'
 ```
 */
package struct Property {
    package var name: String
    package var keyword: Keyword?
    package var value: any Expr?

    package init(name: String = "", keyword: Keyword? = nil, value: any Expr? = nil) {
        self.name = name
        self.keyword = keyword
        self.value = value
    }
}

package final class Handler: Node {
    package var name: String
    /** Set when the handler answers an Apple event, not a named call. */
    package var eventCode: EventCode?
    package var parameters: [Parameter]
    package var body: [any Stmt]
    package var isRunHandler: Bool
    /**
     True for a run handler printed without `on run` and `end run`: its
     statements are at the top level of the script.
     */
    package var isImplicit: Bool
    /** True when the source named the event by its code: `on «event emalcpma»`. */
    package var isRawEvent = false

    package init(
        name: String = "", eventCode: EventCode? = nil, parameters: [Parameter] = [],
        body: [any Stmt] = [], isRunHandler: Bool = false, isImplicit: Bool = false,
    ) {
        self.name = name
        self.eventCode = eventCode
        self.parameters = parameters
        self.body = body
        self.isRunHandler = isRunHandler
        self.isImplicit = isImplicit
    }
}

/**
 The label of a handler parameter, or of an argument of a call to a
 handler.

 ```
 polish to x                  code 'to  '     a preposition
 describe given size:n        code 'ptsz'     a word of the language
 display dialog m buttons b   code 'btns'     a parameter of a command
 describe given flag:f        word "flag"     a word of the script author
 ```
 */
package enum Label: Equatable {
    case code(Code4)
    case word(String)
}

/**
 A handler parameter.

 ```
 on mix(a, b)                 two parameters, no label
 on run argv                  the direct parameter: no label
 on polish to x               label 'to  '
 on pat(a, {b, c})            the second parameter is a pattern
 ```

 A parameter without a label that comes with labeled ones is the direct
 parameter: `on findNumbers of numberList above minLimit`.

 `pattern` is a list or a record of names. When it is set, it is
 printed in place of `name`.
 */
package struct Parameter {
    package var name: String
    package var pattern: any Expr?
    package var label: Label?

    /** The code of the label, when the label is a code. */
    package var code: Code4? {
        if case let .code(code) = label {
            return code
        }
        return nil
    }

    package init(name: String = "", pattern: any Expr? = nil, label: Label? = nil) {
        self.name = name
        self.pattern = pattern
        self.label = label
    }

    package init(name: String, code: Code4) {
        self.init(name: name, label: .code(code))
    }

    /** The variables the parameter sets: its name, or every name of its pattern. */
    package var names: [String] {
        func names(in pattern: any Expr?) -> [String] {
            switch pattern {
            case let node as Variable:
                [node.name]
            case let node as List:
                node.elements.flatMap { names(in: $0) }
            case let node as Record:
                node.fields.flatMap { names(in: $0.value) }
            default:
                []
            }
        }
        return self.pattern.map { names(in: $0) } ?? [self.name]
    }
}

package extension Node {
    /** The name of the kind of the node, for messages: `Keyword`, `SetStmt`, … */
    var nodeName: String {
        String(describing: type(of: self))
    }
}
