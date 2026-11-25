import Extensions
import Terminology

extension SourceFormatter {
    /**
     Prints an expression.

     `place` is the level that the place of the expression asks for
     (see `Precedence`). An expression with a lower level is put in
     parentheses:

     ```
     set x to count y           .statement    nothing has parentheses
     {(count y), a or b}        .value        a command call has them
     (a or b) and c             .and          `or` has them too
     ```

     This function calls itself for each expression inside another one,
     so it is kept small: it only finds the kind of the node. A node
     with nothing inside it is printed by `value`.
     */
    func expr(_ expression: any Expr?, _ place: Precedence = .value) -> String {
        switch expression {
        case let node as List:
            "{" + node.elements.map { self.expr($0) }.joined(separator: ", ") + "}"
        case let node as Record:
            "{" + node.fields.map { self.field($0) }.joined(separator: ", ") + "}"
        case let node as Unary:
            self.unary(node, place)
        case let node as Binary:
            self.binary(node, place)
        case let node as Coerce:
            self.coerce(node, place)
        case let node as GetExpr:
            self.wrap("get " + self.expr(node.value), .value, in: place)
        case let node as Reference:
            // It takes all that follows: `a reference to x + y` is a
            // reference to the sum. So it is bare only where a value ends.
            self.wrap("a reference to " + self.referenced(node.value), .value, in: place)
        case let node as CopyExpr:
            "«copy» " + self.expr(node.value, .term)
        case let node as CommandCall:
            self.wrap(self.commandCall(node), .statement, in: place)
        case let node as LabeledCall:
            self.wrap(self.labeledCall(node), .statement, in: place)
        case let node as HandlerCall:
            if self.isInterleaved(node) {
                self.wrap(self.handlerCall(node), .statement, in: self.insideRepeatWith ? .value : place)
            } else {
                self.handlerCall(node)
            }
        case let node as Specifier:
            self.specifier(node)
        case let node as ScriptObject:
            self.scriptObject(node, 0)
        case let node as ContinueExpr:
            self.wrap(self.continueCall(node), .statement, in: place)
        case let node as Whose:
            self.whose(node, place)
        default:
            self.value(expression)
        }
    }

    /** Prints an expression that has no other expression inside it. */
    func value(_ expression: any Expr?) -> String {
        switch expression {
        case nil, is MissingLiteral:
            "missing value"
        case let node as StringLiteral:
            node.value.stringLiteral
        case let node as NumberLiteral:
            node.isReal ? node.real.realLiteral : String(node.integer)
        case let node as BooleanLiteral:
            node.value ? "true" : "false"
        case let node as DateLiteral:
            "date " + node.value.stringLiteral
        case let node as RawDataLiteral:
            "«data " + node.type.bytes.rawCode + node.data.hex.uppercased() + "»"
        case let node as OpaqueLiteral:
            "«unsupported runtime data type \(node.runtimeType): \(node.data.hex)»"
        case let node as Keyword:
            self.keyword(node)
        case let node as Variable:
            self.name(node.name)
        case let node as Application:
            "application " + node.name.stringLiteral
        case let node as ScriptLibrary:
            "script " + node.name.stringLiteral
        case is Me:
            "me"
        case is It:
            "it"
        case is CurrentApplication:
            "current application"
        default:
            "«unsupported " + (expression?.nodeName ?? "nothing") + "»"
        }
    }

    /**
     Prints a term given by its code. The word comes from the
     terminology; without a word, the raw form is printed:

     ```
     four    name            «class pnam»
     eight   yes             «constant savoyes »
     other                   «constant 4142434445»
     ```

     The two kinds do not share their words. A code of four bytes is a
     class or a property, and a code of eight bytes is an enumerator: the
     compiler makes another value from each. So the name of a class is
     never printed for an enumerator, or the other way round, even when
     both have the same four letters:

     ```
     «constant ****msng»     not `missing value`, which is «class msng»
     «class Kclk»            not `caps lock down`, which is «constant ****Kclk»
     ```

     Apple's tools print these two raw forms too.
     */
    func keyword(_ node: Keyword) -> String {
        if !node.fallback.isEmpty {
            return node.fallback
        }
        switch node.code {
        case let .four(code)?:
            return self.terms?.term(code) ?? code.rawClass
        case let .eight(constant)?:
            // The whole code is tried first, then its second half alone.
            let member = constant.second
            return self.terms?.constant(constant) ?? self.terms?.enumeration(member)
                ?? "«constant " + constant.first.bytes.rawCode + member.bytes.rawCode + "»"
        case let .other(bytes)?:
            return "«constant " + bytes.hex + "»"
        case nil:
            return "«constant »"
        }
    }

    /**
     Prints one field of a record: `label:value`. A label that is text
     is a user word, and is printed as an identifier.
     */
    func field(_ field: RecordField) -> String {
        var label = self.expr(field.label)
        if let text = field.label as? StringLiteral {
            label = self.name(text.value)
        }
        return label + ":" + self.expr(field.value)
    }

    /** Puts `text` in parentheses when its level is lower than what its place asks for. */
    func wrap(_ text: String, _ level: Precedence, in place: Precedence) -> String {
        level < place ? "(" + text + ")" : text
    }

    /**
     Prints `object whose test`. The test takes all that follows, so
     with an operator the whole has parentheses:
     `(every item of x whose n = 1) as text`.

     As the container of something it has parentheses too. Without
     them the text is another tree, the one the compiler makes for a
     filter on the whole reference:

     ```
     name of (every file whose n = 1)     the name of each file that passes
     name of every file whose n = 1       a filter on `name of every file`
     ```
     */
    func whose(_ node: Whose, _ place: Precedence) -> String {
        self.wrap(self.expr(node.object) + " whose " + self.expr(node.predicate), .value, in: place)
    }

    /**
     Prints what `a reference to` points at. The compiler stores a
     variable `x` there as `x of me`, and the source has only the name.
     */
    func referenced(_ value: any Expr?) -> String {
        if let node = value as? Specifier, node.kind == .property, node.container is Me, let name = node.object as? Variable {
            return self.name(name.name)
        }
        return self.expr(value, .term)
    }

    /** Prints `continue call`, without parentheses around it. */
    func continueCall(_ node: ContinueExpr) -> String {
        node.call == nil ? "continue «unresolved»" : "continue " + self.expr(node.call, .statement)
    }

    /**
     Prints `not x` or `-x`.

     The operand of `not` is always one term: `not (a = b)` is easier to
     read than `not a = b`, which means the same.
     */
    func unary(_ node: Unary, _ place: Precedence) -> String {
        if node.op == .not {
            return self.wrap("not " + self.expr(node.value, .term), .not, in: place)
        }
        // A minus sign can only be put in front of a name or a number:
        // `-item 3 of x` and `-f(x)` do not compile. And two minus
        // signs start a comment: the opposite of -5 is `-(-5)`.
        let text = self.expr(node.value)
        if node.value is Variable || node.value is NumberLiteral, !text.hasPrefix("-") {
            return "-" + text
        }
        return "-(" + text + ")"
    }

    /**
     Prints `left op right`.

     The right side asks for more than the level of the operator. The
     left side asks for the level itself when the operator groups from
     the left (see `groupsFromLeft`), and for more when it does not:

     ```
     a - b - c        `(a - b) - c` needs no parentheses
     a - (b - c)      the right side asks for more than `-`
     (a = b) = c      both sides ask for more than `=`
     ```
     */
    func binary(_ node: Binary, _ place: Precedence) -> String {
        let level = node.op.precedence
        if let text = self.runningTest(node) {
            return self.wrap(text, level, in: place)
        }
        var left = node.left
        var right = node.right
        if node.op == .and || node.op == .or {
            left = left?.withoutBooleanCoercion
            right = right?.withoutBooleanCoercion
        }
        let text = self.operand(left, node.op.groupsFromLeft ? level : level.next, of: node.op, isRight: false) + " "
            + node.op.rawValue + " " + self.operand(right, level.next, of: node.op, isRight: true)
        return self.wrap(text, level, in: place)
    }

    /**
     Prints one side of the operation `op`.

     Apple's tools write parentheses around some operands of an
     arithmetic operator (`+ - * / div mod ^`) that the compiler does not
     need. The printer writes the same, so that its source is printed
     unchanged by them:

     ```
     (name of x) + 1         a reference, on each side (see `isReference`)
     (my size()) * 2
     2 * (size())            a call or a power, on the right of
     2 * (a ^ b)             `* / div mod ^`
     name of x & "!"         no parentheses with the other operators
     ```

     They do the same for a coercion beside `contains`, `starts with`
     and `ends with`, on each side. The compiler reads `as` first there
     with or without them, but their printer has `as` below these three:

     ```
     a contains (b as text)       typed as `a contains b as text`
     (a as text) starts with b
     a = b as text                no parentheses with `=` and `<`
     ```
     */
    func operand(_ expression: any Expr?, _ place: Precedence, of op: BinaryKind, isRight: Bool) -> String {
        let text = self.expr(expression, place)
        if op == .contains || op == .startsWith || op == .endsWith, expression is Coerce {
            return "(" + text + ")"
        }
        guard op.isArithmetic else {
            return text
        }
        if self.isReference(expression) {
            return "(" + text + ")"
        }
        // On the right of `* / div mod ^`: a call, and a power.
        if isRight, op != .add, op != .subtract {
            if let call = expression as? HandlerCall, !self.isInterleaved(call) {
                return "(" + text + ")"
            }
            if let power = expression as? Binary, power.op == .power, !text.isParenthesized {
                return "(" + text + ")"
            }
        }
        return text
    }

    /**
     Prints an expression where the source wants one term: an end of a
     range, an argument written after a colon. A name, a number, a text
     or a list is written as it is. Anything else is in parentheses, as
     Apple's tools write it:

     ```
     items i thru (count of x)
     x's setValue:(missing value) forKey:(name of y)
     ```
     */
    func term(_ expression: any Expr?) -> String {
        switch expression {
        case is Variable, is StringLiteral, is NumberLiteral, is BooleanLiteral, is List, is Record, is Me, is It:
            return self.expr(expression)
        default:
            let text = self.expr(expression, .term)
            return text.isParenthesized ? text : "(" + text + ")"
        }
    }

    /**
     True for an expression that names something inside something else,
     or that is asked to another object:

     ```
     name of x      item 1 of x     x's size()      application "Finder"
     item 1         window id 7     my size()       script "Tools"
     ```

     `name`, `every item` and `items 1 thru 2` alone, with no container
     written, are not: Apple's tools print them bare.
     */
    func isReference(_ expression: any Expr?) -> Bool {
        switch expression {
        case is Application, is ScriptLibrary:
            true
        case let node as Specifier:
            switch node.kind {
            case .index, .key, .beginning, .end, .before, .after:
                true
            default:
                (node.container != nil && !(node.container is It)) || self.needsIts(node)
            }
        case let node as HandlerCall:
            node.target != nil && !self.isInterleaved(node)
        case let node as Binary:
            node.op == .of
        default:
            false
        }
    }

    /**
     Prints `value as type`. The type is one term: what comes after it
     is never read as a part of the type.
     */
    func coerce(_ node: Coerce, _ place: Precedence) -> String {
        self.wrap(self.expr(node.value, .coercion) + " as " + self.expr(node.type, .term), .coercion, in: place)
    }

    /**
     Prints `application "X" is running`. The compiler stores it as a
     comparison of the property `running` with `true`.

     - Returns: `nil` when the operation is not this test.
     */
    func runningTest(_ node: Binary) -> String? {
        guard
            node.op == .equal || node.op == .notEqual,
            (node.right as? BooleanLiteral)?.value == true,
            let property = node.left as? Specifier,
            property.kind == .property,
            (property.object as? Keyword)?.code == .four("prun"),
            let target = property.container as? Application
        else {
            return nil
        }
        return self.expr(target, .reference) + (node.op == .equal ? " is running" : " is not running")
    }
}

extension Expr {
    /**
     The value without `as boolean` around it: `(x as boolean)` gives `x`.
     A coercion of nothing gives `nil`.
     */
    var withoutBooleanCoercion: any Expr? {
        var value: any Expr? = self
        while let coerce = value as? Coerce, let keyword = coerce.type as? Keyword, keyword.code == .four("bool") {
            value = coerce.value
        }
        return value
    }
}
