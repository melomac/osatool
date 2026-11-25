import AST
import Extensions
import Terminology

/**
 The `strings` pass: puts back together text that was cut into pieces.

 Obfuscated scripts often build a string from small parts:

 ```
 set a to "cu"                         set a to "cu"
 set b to a & "rl " & (ASCII           set b to "curl -"
     character 45)                →
 do shell script b                     do shell script b
 ```

 AppleScript's `&` joins text, but it also joins lists and records. So
 the pass folds a chain of `&` only when every operand is proven to be
 text. A chain with an operand of unknown type is left as it is.
 */
package struct Strings: Pass {
    package init() {}

    package var name: String {
        "strings"
    }

    package func rewrite(_ script: Script) -> (Script, [Diagnostic]) {
        let finder = SharedNames()
        finder.read(script.members)
        let level = StringLevel(names: script.members.memberNames, shared: finder.names, trackLocals: true)
        self.rewrite(&script.properties, script.handlers, level)
        script.objects.forEach { self.rewrite($0, inside: level) }
        return (script, [])
    }

    /**
     Rewrites a script object, and the script objects defined inside it.

     - `outer`: the level around the script object. Its names stay
       shared inside: a handler of the script object can set a property
       of the script around it.
     */
    func rewrite(_ object: ScriptObject, inside outer: StringLevel) {
        var level = outer
        level.names.formUnion(object.members.memberNames)
        // The run handler of a script object has locals, not globals.
        level.shared = []
        self.rewrite(&object.properties, object.handlers, level)
        object.objects.forEach { self.rewrite($0, inside: level) }
    }

    /**
     Rewrites the values of some properties, then each handler with
     facts of its own.
     */
    func rewrite(_ properties: inout [Property], _ handlers: [Handler], _ level: StringLevel) {
        for index in properties.indices {
            properties[index].value = StringEnvironment().rewrite(properties[index].value)
        }
        for handler in handlers {
            let scope = StringScope(
                blocked: handler.blockedVariables(level),
                trackLocals: level.trackLocals && !handler.body.letsLocalsEscape,
            )
            StringEnvironment().rewrite(handler.body, scope)
        }
    }
}

/**
 What a script, or a script object, gives to the handlers written in it.

 ```
 property p : "a"            names of the script:  p, s, helper
 script s
     property q : 1          names inside s:       p, s, helper, q, f
     on f() … end f
 end script
 on helper() … end helper
 ```
 */
struct StringLevel {
    /**
     The names of this level and of the levels around it: properties,
     script objects and handlers. Another handler can change them, so a
     handler does not track them.
     */
    var names: Set<String>
    /** The globals that code outside the run handler of the script can change: see `SharedNames`. */
    var shared: Set<String>
    /** False inside a script object made in a handler, whose variables can come from that handler. */
    var trackLocals: Bool
}

/**
 Finds the globals of a script that more than one handler can reach.

 In the run handler of a script, a plain name is a global. Another
 handler does not see it under that name, but it has two ways to reach
 it:

 ```
 set a to "x"            on f()                 on g()
 f()                         global a               set my a to 5
 return a & "y"              set a to 5         end g
                         end f
 ```

 After `f()`, or `g()`, `a` is 5. So the run handler tracks a global
 only when no `global` line names it, anywhere in the script, and no
 code reads or sets it as a property of an object (`my a`, `a of me`,
 `a of x`, `a reference to a`).

 A script loaded from another file, and given this script as its
 parent, could still change a global. The pass does not see that.
 */
final class SharedNames {
    /** The names found, as keys: see `variableKey`. */
    var names: Set<String> = []

    /** Reads the members of a script or of a script object, and what is inside them. */
    func read(_ members: [Member]) {
        for member in members {
            switch member {
            case .use:
                break
            case let .globals(line):
                self.names.formUnion(line.names.map(\.variableKey))
            case let .property(property):
                _ = self.read(property.value)
            case let .object(object):
                self.read(object.members)
            case let .handler(handler):
                self.read(handler.body)
            }
        }
    }

    /** Reads some statements, and the blocks inside them. */
    func read(_ statements: [any Stmt]) {
        for statement in statements {
            if let line = statement as? Declaration, line.global {
                self.names.formUnion(line.names.map(\.variableKey))
            }
            statement.rewriteExpressions(self.read)
            statement.bodies.forEach(self.read)
        }
    }

    /** Reads an expression and its parts. It returns the expression unchanged. */
    func read(_ expression: any Expr?) -> (any Expr)? {
        guard let expression else {
            return nil
        }
        if let object = expression as? ScriptObject {
            self.read(object.members)
            return expression
        }
        if let node = expression as? Specifier, node.kind == .property, let name = node.object as? Variable {
            self.names.insert(name.name.variableKey)
        }
        expression.rewriteChildren(self.read)
        return expression
    }
}

extension [Member] {
    /** The names declared at this level: properties, script objects and handlers. */
    var memberNames: Set<String> {
        var names: Set<String> = []
        for member in self {
            switch member {
            case .use, .globals:
                break
            case let .property(property):
                names.insert(property.name.variableKey)
            case let .object(object):
                names.insert(object.name.variableKey)
            case let .handler(handler):
                names.insert(handler.name.variableKey)
            }
        }
        return names
    }
}

/**
 What is known about a variable: it holds text. When `constant` is true,
 the exact text is also known and is in `value`.
 */
struct StringFact: Equatable {
    var value = ""
    var constant = false
}

/** What stays the same while one handler is rewritten. */
struct StringScope {
    /** The variables whose value is not tracked: see `Handler.blockedVariables`. */
    var blocked: Set<String>
    /** False when a local can change without a visible assignment. */
    var trackLocals: Bool
}

/**
 The facts known at one point of a handler: variable name → fact.

 It is a class because a block and the blocks nested in it (`tell`,
 `considering`, `with timeout`) work on the same set of facts.
 */
final class StringEnvironment {
    var facts: [String: StringFact]

    init(_ facts: [String: StringFact] = [:]) {
        self.facts = facts
    }

    func clone() -> StringEnvironment {
        StringEnvironment(self.facts)
    }

    func clear() {
        self.facts.removeAll()
    }

    /** Keeps only the facts that are the same in the two branches. */
    func keepCommon(_ left: StringEnvironment, _ right: StringEnvironment) {
        self.clear()
        for (name, value) in left.facts {
            if let other = right.facts[name], other == value {
                self.facts[name] = value
            }
        }
    }

    /**
     Rewrites the statements of a block, in order, and keeps the facts up
     to date after each assignment.

     Control flow decides what stays known after a block:

     ```
     if / else     keep only the facts that both branches agree on
     repeat        forget everything (the body may run many times)
     try           forget everything (the body may stop anywhere)
     tell, …       same facts as the surrounding block
     ```
     */
    func rewrite(_ statements: [any Stmt], _ scope: StringScope) {
        for statement in statements {
            switch statement {
            case let node as SetStmt:
                node.rewriteExpressions(self.rewrite)
                self.assign(node.target, node.value, scope)
            case let node as Copy:
                node.rewriteExpressions(self.rewrite)
                self.assign(node.target, node.source, scope)
            case is Expression, is ErrorStmt, is Return:
                statement.rewriteExpressions(self.rewrite)
            case let node as Declaration:
                for name in node.names {
                    self.facts[name.variableKey] = nil
                }
            case let node as If:
                node.condition = self.rewrite(node.condition)
                let thenEnvironment = self.clone()
                let elseEnvironment = self.clone()
                thenEnvironment.rewrite(node.then, scope)
                elseEnvironment.rewrite(node.else, scope)
                self.keepCommon(thenEnvironment, elseEnvironment)
            case let node as Repeat:
                // The header is read with no fact: the loop can change any variable.
                node.rewriteExpressions(StringEnvironment().rewrite)
                StringEnvironment().rewrite(node.body, scope)
                self.clear()
            case let node as Try:
                self.clone().rewrite(node.body, scope)
                StringEnvironment().rewrite(node.errorBody, scope)
                self.clear()
            case is Tell, is Considering, is Timeout, is UsingTerms:
                // The body runs once, in order: it works on the same facts.
                statement.rewriteExpressions(self.rewrite)
                statement.bodies.forEach { self.rewrite($0, scope) }
            case is ExitRepeat, is Comment, is Blank:
                // These statements contain no expressions and cannot change facts.
                break
            default:
                // Keep newly added statement kinds safe until their control-flow
                // and mutation behavior is handled explicitly.
                self.clear()
            }
        }
    }

    /** Rewrites an expression: its parts first, then the expression itself. */
    func rewrite(_ expression: any Expr?) -> (any Expr)? {
        guard let expression else {
            return nil
        }
        if let chain = expression as? Binary, chain.op == .concatenate {
            // The chain is read as a whole: its operands are rewritten there.
            return self.fold(chain)
        }
        if let object = expression as? ScriptObject {
            // A nested script may capture bindings from its containing handler.
            // Rewrite context-free expressions, but do not propagate its locals.
            Strings().rewrite(object, inside: StringLevel(names: [], shared: [], trackLocals: false))
        } else {
            expression.rewriteChildren(self.rewrite)
        }
        return expression.foldedText
    }

    /**
     Rewrites a chain of `&`, with its operands, and folds every part of
     it whose operands are all proven to be text.

     Such a part is made flat, then literals that touch each other are
     joined:

     ```
     "a" & "b" & x & "c" & "d"     (x is text, value unknown)
       →  "ab" & x & "cd"
     ```

     A part with an operand that is not proven to be text keeps its
     shape. With `l` a list, `l & "c" & "d"` is not `l & "cd"`:

     ```
     "a" & "b" & l & "c" & "d"     →  "ab" & l & "c" & "d"
     ```

     The whole chain is read once. Reading it again at each `&` took a
     time that grew with the cube of its length: 14 seconds for 2,000
     operands.
     */
    func fold(_ expression: Binary) -> any Expr {
        var operands: [any Expr?] = []
        let whole = self.chainSide(expression, &operands)
        return (whole.isText ? self.joined(operands[...]) : whole.side) ?? expression
    }

    /**
     Rewrites one side of a `&`, and tells whether it is proven to be text.

     When it is, its operands are added to `operands`, from left to
     right, a variable with a known text being replaced by that text.
     The `&` nodes of such a side are not kept: the caller joins the
     operands again. When it is not, `operands` is left as it was.

     - Returns: the side, rewritten, and true when it is text.
     */
    func chainSide(_ side: any Expr?, _ operands: inout [any Expr?]) -> (side: any Expr?, isText: Bool) {
        guard
            let node = side as? Binary,
            node.op == .concatenate
        else {
            let operand = self.rewrite(side)
            guard let fact = self.fact(of: operand) else {
                return (operand, false)
            }
            operands.append(fact.constant ? StringLiteral(value: fact.value) : operand)
            return (operand, true)
        }
        let start = operands.count
        let leftIsChain = (node.left as? Binary)?.op == .concatenate
        let rightIsChain = (node.right as? Binary)?.op == .concatenate
        let left = self.chainSide(node.left, &operands)
        let middle = operands.count
        let right = self.chainSide(node.right, &operands)
        if left.isText, right.isText {
            return (node, true)
        }
        // One side is not text: this `&` stays, and a side that is a
        // chain of text is folded on its own.
        node.right = right.isText && rightIsChain ? self.joined(operands[middle...]) : right.side
        node.left = left.isText && leftIsChain ? self.joined(operands[start ..< middle]) : left.side
        operands.removeSubrange(start...)
        return (node, false)
    }

    /**
     Builds `a & b & c`, grouped from the left, from operands that are
     all text. Literals that touch each other become one literal.
     */
    func joined(_ operands: ArraySlice<any Expr?>) -> (any Expr)? {
        var result: any Expr?
        var text = ""
        var hasText = false
        func add(_ operand: any Expr?) {
            result = result == nil ? operand : Binary(op: .concatenate, left: result, right: operand)
        }
        for operand in operands {
            if let literal = operand as? StringLiteral {
                text += literal.value
                hasText = true
                continue
            }
            if hasText {
                add(StringLiteral(value: text))
                (text, hasText) = ("", false)
            }
            add(operand)
        }
        if hasText {
            add(StringLiteral(value: text))
        }
        return result
    }

    /**
     Decides whether an expression is text.

     - Returns: `nil` when this is not proven. If not `nil`, a fact; its
       `constant` flag tells whether the exact text is known.

     Proven text: a string literal, a tracked variable, a chain of `&` over
     text, `x as string|text|Unicode text`, the result of `do shell script`,
     `quoted form of x`, `POSIX path of x`, and the constants `space`, `tab`,
     `linefeed` and `return`.
     */
    func fact(of expression: any Expr?) -> StringFact? {
        switch expression {
        case let node as StringLiteral:
            return StringFact(value: node.value, constant: true)
        case let node as Variable:
            return self.facts[node.name.variableKey]
        case let node as Binary:
            if node.op == .of, node.left.isKeyword(named: "quoted form", "POSIX path") {
                return StringFact()
            }
            guard
                node.op == .concatenate,
                let left = self.fact(of: node.left),
                let right = self.fact(of: node.right)
            else {
                return nil
            }
            return left.constant && right.constant ? StringFact(value: left.value + right.value, constant: true) : StringFact()
        case let node as Coerce:
            return node.type.isKeyword(named: "string", "text", "Unicode text") ? StringFact() : nil
        case let node as CommandCall:
            return node.isScriptCommand("sysoexec") ? StringFact() : nil
        case let node as Specifier:
            return node.object.isKeyword(named: "quoted form", "POSIX path") ? StringFact() : nil
        case let node as Keyword:
            return Optional(node).isKeyword(named: "space", "tab", "linefeed", "return") ? StringFact() : nil
        default:
            return nil
        }
    }

    /**
     Updates the facts after `set target to value` (or `copy value to target`).

     Only a plain local variable is tracked. Any other target removes
     what was known about every variable it names:

     ```
     set item 1 of x to …        x
     set {a, {b, c}} to …        a, b and c: each one gets a part of the value
     set {p:a, q:b} to …         a and b
     set a of x to …             x, and a
     ```

     So does an assignment to a blocked variable, or with tracking
     turned off.
     */
    func assign(_ target: any Expr?, _ value: any Expr?, _ scope: StringScope) {
        guard let variable = target as? Variable else {
            for key in target?.namedVariables ?? [] {
                self.facts[key] = nil
            }
            return
        }
        let key = variable.name.variableKey
        guard
            scope.trackLocals,
            !scope.blocked.contains(key)
        else {
            self.facts[key] = nil
            return
        }
        // Dynamic producers establish only a type fact; known constants retain
        // their value. Both can be shared safely because AppleScript text is
        // immutable.
        self.facts[key] = self.fact(of: value)
    }
}

extension Handler {
    /**
     Returns the variables whose value must not be tracked in the handler:
     the names of the level (another handler may change them) and the
     globals. A parameter or a `local` with the same name hides a name
     of the level.

     In the run handler of the script, a name with no `local` line is a
     global, and the shared ones are not tracked either. A script
     object has a run handler too, but its names are locals: the
     compiler was asked.
     */
    func blockedVariables(_ level: StringLevel) -> Set<String> {
        var blocked = level.names
        blocked.subtract(self.parameters.flatMap(\.names).map(\.variableKey))
        if self.isRunHandler {
            blocked.formUnion(level.shared)
        }
        let (locals, globals) = self.body.declaredVariables
        return blocked.subtracting(locals).union(globals)
    }
}

extension [any Stmt] {
    /**
     True when a handler lets a local variable be reached from outside its
     normal flow: `a reference to x`, or a nested script object. In that case
     the value of a local can change without a visible assignment.
     */
    var letsLocalsEscape: Bool {
        var found = false
        self.rewriteEveryExpression { expression in
            if expression is Reference || expression is ScriptObject {
                found = true
            }
            return expression
        }
        return found
    }

    /**
     The names declared with `local` and with `global`, in the blocks
     the pass reads: not inside `with transaction`.
     */
    var declaredVariables: (locals: Set<String>, globals: Set<String>) {
        var locals: Set<String> = []
        var globals: Set<String> = []
        func visit(_ statements: [any Stmt]) {
            for statement in statements {
                if let node = statement as? Declaration {
                    let names = node.names.map(\.variableKey)
                    if node.global {
                        globals.formUnion(names)
                    } else {
                        locals.formUnion(names)
                    }
                }
                if !(statement is Transaction) {
                    statement.bodies.forEach(visit)
                }
            }
        }
        visit(self)
        return (locals, globals)
    }
}

extension String {
    /** AppleScript names ignore letter case, so facts use lowercase keys. */
    var variableKey: String {
        self.lowercased()
    }
}

extension Expr {
    /** The keys of all the variables named in the expression, at any depth. */
    var namedVariables: Set<String> {
        var names: Set<String> = []
        _ = self.rewriteWithChildren { expression in
            if let variable = expression as? Variable {
                names.insert(variable.name.variableKey)
            }
            return expression
        }
        return names
    }

    /**
     The expression after the rewrites that need no context:

     - `"a" & "b"` becomes `"ab"`;
     - `ASCII character n` (0 ≤ n ≤ 127) becomes the one-character string.

     Lists are not collapsed on purpose: that would change their shape.
     */
    var foldedText: any Expr {
        switch self {
        case let node as Binary:
            if node.op == .concatenate, let left = node.left as? StringLiteral, let right = node.right as? StringLiteral {
                return StringLiteral(value: left.value + right.value)
            }
        case let node as CommandCall:
            if node.isScriptCommand("sysontoc"), node.arguments.count == 1, let direct = node.arguments[0] as? DirectArgument,
               let number = direct.value as? NumberLiteral, !number.isReal, number.integer >= 0, number.integer <= 127
            {
                return StringLiteral(value: String(Unicode.Scalar(UInt8(number.integer))))
            }
        default:
            break
        }
        return self
    }
}

extension CommandCall {
    /**
     True when the call is the Standard Additions command with this event
     code, sent to the script itself (no target, or `me`).
     */
    func isScriptCommand(_ code: EventCode) -> Bool {
        self.code == code && (self.target == nil || self.target is Me)
    }
}

extension (any Expr)? {
    /**
     True when the expression is a keyword with one of the given names.

     The raw code decides when there is one (its last four bytes). The
     printed `fallback` text is used only for a keyword without a code.
     */
    func isKeyword(named names: String...) -> Bool {
        guard let keyword = self as? Keyword else {
            return false
        }
        let bytes = keyword.code?.bytes ?? []
        let code = bytes.count >= 4 ? Array(bytes.suffix(4)) : bytes
        if let keywordName = stringKeywordNames[String(decoding: code, as: UTF8.self)] {
            return names.contains { $0.lowercased() == keywordName.lowercased() }
        }
        if keyword.code != nil {
            return false
        }
        return names.contains { $0.lowercased() == keyword.fallback.lowercased() }
    }
}

/** The names of the keywords the pass knows, by their code. */
let stringKeywordNames: [String: String] = [
    "strq": "quoted form",
    "psxp": "POSIX path",
    "spac": "space",
    "tab ": "tab",
    "lnfd": "linefeed",
    "ret ": "return",
    "TEXT": "string",
    "ctxt": "text",
    "utxt": "Unicode text",
]
