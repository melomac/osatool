import Extensions
import Terminology

extension SourceFormatter {
    /**
     Prints an object specifier: what is asked for, then ` of container`.

     ```
     property    name of x                  beginning   beginning of x
     index       item 3 of x                end         end of x
     key         window id 7 of x           every       every item of x
     range       items 2 thru 4 of x        middle      middle item of x
     before      window before window 2     some        some item of x
     after       window after window 1
     ```
     */
    func specifier(_ node: Specifier) -> String {
        // `application id "x"` is stored with `of me`, which the source does not have.
        if node.applicationName != nil {
            return self.specifier(node.withoutContainer)
        }
        return switch node.kind {
        case .range:
            self.inContainer(self.rangeClass(node.object) + " " + self.rangeBounds(node), node)
        case .index:
            self.inContainer(self.expr(node.object, .reference) + " " + self.selector(node.from), node)
        case .key:
            self.keySpecifier(node)
        case .property:
            if let raw = self.rawPluralProperty(node) ?? self.rawTargetProperty(node) {
                self.inContainer(raw, node)
            } else if self.needsIts(node) {
                "its " + self.expr(node.object, .reference)
            } else {
                self.inContainer(self.expr(node.object, .reference), node)
            }
        case .every:
            self.inContainer(self.isBarePlural(node) ? self.expr(node.object) : "every " + self.expr(node.object), node)
        case .before:
            self.relativeClass(node) + "before " + self.expr(node.container, .reference)
        case .after:
            self.relativeClass(node) + "after " + self.expr(node.container, .reference)
        case .beginning:
            "beginning of " + self.expr(node.container, .reference)
        case .end:
            "end of " + self.expr(node.container, .reference)
        case .middle:
            self.inContainer("middle " + self.expr(node.object), node)
        case .some:
            self.inContainer("some " + self.expr(node.object), node)
        }
    }

    /**
     True for a property of `it` that must be written `its name`, and
     not with the word alone. In a `tell` block:

     ```
     n            a variable of the script      its n            a property of the target
     container    the class named `container`   its container    a property of the target
     name         the property, both ways
     ```

     So `its` is kept for a word of the user, and for a word that is
     also the name of a class.
     */
    func needsIts(_ node: Specifier) -> Bool {
        guard
            node.kind == .property,
            node.container is It
        else {
            return false
        }
        if node.object is Variable {
            return true
        }
        if let keyword = node.object as? Keyword, keyword.fallback.isEmpty, case let .four(code)? = keyword.code {
            return self.terms?.plural(code) != nil
        }
        return false
    }

    /**
     True for `every text of x`, which is printed `text of x`: the name
     of the class is also its plural (see `Registry.isOwnPlural`), so
     the compiler reads the short form the same way, and it is the form
     people write. Without a container the word alone is the class, and
     `every` stays.
     */
    func isBarePlural(_ node: Specifier) -> Bool {
        guard
            let container = node.container,
            !(container is It),
            let keyword = node.object as? Keyword,
            keyword.fallback.isEmpty,
            case let .four(code)? = keyword.code
        else {
            return false
        }
        return self.terms?.isOwnPlural(code) == true
    }

    /**
     Returns the raw form of a property whose code is a class that is
     its own plural, or `nil` for any other property. The compiler
     reads the word as the plural, so the word cannot name the property:

     ```
     «property ctxt» of x     the property
     text of x                every text of x
     ```
     */
    func rawPluralProperty(_ node: Specifier) -> String? {
        guard
            let keyword = node.object as? Keyword,
            keyword.fallback.isEmpty,
            case let .four(code)? = keyword.code,
            self.terms?.isOwnPlural(code) == true
        else {
            return nil
        }
        return code.rawProperty
    }

    /**
     Returns the raw form of a property of the target whose code has no
     word here, or `nil` for any other property. With no container to
     name, the raw form of a class would be the class itself, which is
     another value:

     ```
     «property sdsk»     the property of the target
     «class sdsk»        the class
     ```

     With a container the two forms compile to the same code, and
     `«class sdsk» of x` is what Apple's tools print.
     */
    func rawTargetProperty(_ node: Specifier) -> String? {
        guard
            node.container == nil || node.container is It,
            let keyword = node.object as? Keyword,
            keyword.fallback.isEmpty,
            case let .four(code)? = keyword.code,
            self.terms?.term(code) == nil
        else {
            return nil
        }
        return code.rawProperty
    }

    /**
     Adds ` of container` to `text`, when there is a container to name.
     `of it` is not printed: inside a `tell` block the target is implied.
     */
    func inContainer(_ text: String, _ node: Specifier) -> String {
        guard
            let container = node.container,
            !(container is It)
        else {
            return text
        }
        // `out of x` is the property `out`: `|out| of x` (see `before`).
        let head = self.before(text, "of", barred: self.barring.specifier(node.withoutContainer))
        return head + " of " + self.expr(container, .reference)
    }

    /**
     Prints the class of a relative form, with a space after it:
     `window ` in `window after window 1`. A place to put something,
     as in `make new folder at after file 1`, has no class to name.
     */
    func relativeClass(_ node: Specifier) -> String {
        if (node.object as? Keyword)?.code == .four("insl") {
            return ""
        }
        return self.expr(node.object) + " "
    }

    /**
     Prints the two ends of a range:

     ```
     items 2 thru 4                         two numbers
     items (i + 1) thru (count of x)        each end is one term
     text from word 2 to word 4             each end is an object of the container
     ```

     In the last form the compiler stores `word 2 of x thru word 4 of
     x`, with the container itself (the same object) in each end.
     */
    func rangeBounds(_ node: Specifier) -> String {
        if let container = node.container, let from = node.from as? Specifier, let to = node.to as? Specifier,
           from.container === container, to.container === container
        {
            return "from " + self.specifier(from.withoutContainer) + " to " + self.specifier(to.withoutContainer)
        }
        return self.term(node.from) + " thru " + self.term(node.to)
    }

    /**
     Prints the class of a range. It is written with the plural name of
     the class, when the terminology has one: `items 2 thru 4`.
     */
    func rangeClass(_ object: any Expr?) -> String {
        let name = self.expr(object)
        if let keyword = object as? Keyword, keyword.fallback.isEmpty, case let .four(code)? = keyword.code,
           self.terms?.term(code) == name, let plural = self.terms?.plural(code)
        {
            return plural
        }
        return name
    }

    /**
     Prints what selects one object: the index in `item 3 of x`, the name
     in `window "a" of x`, the key in `window id 7 of x`.

     A name, a number or a text is written as it is. Anything else is in
     parentheses, because `of` would take it apart:

     ```
     item (item i of order) of names     not `item item i of order of names`,
                                         which is item (item i of (order of names))
     window (name of w) of x
     item (i + 1) of x
     item -1 of x
     character id of x                   a property of the target, with no `of`
     ```
     */
    func selector(_ expression: any Expr?) -> String {
        if let minus = expression as? Unary, minus.op == .negate, minus.value is NumberLiteral || minus.value is Variable {
            return self.expr(expression)
        }
        // A word given by its code is one term. So is a property of the
        // target, written as its word alone: `character id of x`.
        if expression is Keyword {
            return self.expr(expression)
        }
        if let property = expression as? Specifier, property.kind == .property, property.container == nil || property.container is It,
           !self.needsIts(property), self.rawPluralProperty(property) == nil
        {
            return self.expr(expression)
        }
        return self.term(expression)
    }

    /** Prints an object given by a key: `window id 7 of x`, `item named "a" of x`. */
    func keySpecifier(_ node: Specifier) -> String {
        let keyName = node.keyName.isEmpty ? "id" : node.keyName
        let text = self.expr(node.object, .reference) + " " + keyName + " " + self.selector(node.from)
        // `character id 65` makes text from a code point. The compiler
        // gives it `me` as its container, which the source does not have.
        // So for that form, `of it` is the container that must be printed.
        if let code = (node.object as? Keyword)?.code, textClasses.contains(code) {
            if node.container is Me {
                return text
            }
            if node.container is It {
                return text + " of it"
            }
        }
        return self.inContainer(text, node)
    }
}

/** The classes for which `id` makes text from code points: `character id 65`. */
let textClasses: Set<KeywordCode> = [.four("cha "), .four("utxt")]

private extension Specifier {
    /** A copy that names no container: `word 2 of x` gives `word 2`. */
    var withoutContainer: Specifier {
        Specifier(kind: self.kind, object: self.object, container: nil, from: self.from, to: self.to, keyName: self.keyName)
    }
}
