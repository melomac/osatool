import AST
import Bytecode
import Extensions
import FAS
import Model
import Terminology

extension State {
    /**
     Builds a comparison inside a `whose` clause. `index` selects the
     operator, with the same numbering as the opcode bytes 0 to 12:

     ```
     0 to 8   a comparison      9 and      10 or      11 not
     ```
     */
    func makeComparison(_ index: UInt8) {
        let kind: BinaryKind
        switch index {
        case 9:
            kind = .and
        case 10:
            kind = .or
        case 11:
            self.push(Unary(op: .not, value: self.pop()))
            return
        default:
            guard let op = Operator(byte: index) else {
                return
            }
            kind = BinaryKind(op)
        }
        let right = self.pop()
        let left = self.pop()
        self.push(Binary(op: kind, left: left, right: right))
    }

    /**
     Builds an object specifier from the stack. The container is under
     what the form needs:

     ```
     property, every, some, middle     container, object
     index                             container, object, index
     key                               container, object, key, key form
     range                             container, object, from, to
     before, after                     the other object, class
     beginning, end                    container
     whose                             object, test
     ```
     */
    func makeSpecifier(_ form: SpecifierForm) {
        switch form {
        case .property: self.push(self.propertySpecifier())
        case .every: self.push(self.everySpecifier())
        case .some: self.push(self.elementSpecifier(.some))
        case .middle: self.push(self.elementSpecifier(.middle))
        case .index: self.push(self.indexSpecifier())
        case .key: self.push(self.keySpecifier())
        case .range: self.push(self.rangeSpecifier())
        case .before: self.push(self.elementSpecifier(.before))
        case .after: self.push(self.elementSpecifier(.after))
        case .beginning: self.push(Specifier(kind: .beginning, container: self.pop()))
        case .end: self.push(Specifier(kind: .end, container: self.pop()))
        case .whose: self.push(self.whoseClause())
        }
    }

    /** `name of x`. A name stored as text is a word of the user: `alpha of x`. */
    func propertySpecifier() -> Specifier {
        var object = self.pop()
        let container = self.pop()
        if let text = object as? StringLiteral, text.value.isName {
            object = Variable(name: text.value)
        }
        return Specifier(kind: .property, object: object, container: container)
    }

    /**
     `every item of x`. The compiler stores `properties of x` as every
     `prop` of x; like osadecompile, the tool prints the word.
     */
    func everySpecifier() -> Specifier {
        let object = self.pop()
        let container = self.pop()
        if let keyword = object as? Keyword, keyword.code == .four("prop") {
            return Specifier(kind: .property, object: Keyword(code: keyword.code, fallback: "properties"), container: container)
        }
        return Specifier(kind: .every, object: object, container: container)
    }

    /**
     A form made of a class and one other object: `some item of x`,
     `middle item of x`, `window after window 1`.
     */
    func elementSpecifier(_ kind: SpecifierKind) -> Specifier {
        let object = self.pop()
        let container = self.pop()
        return Specifier(kind: kind, object: object, container: container)
    }

    /** `item 3 of x`. The compiler reads the index by itself: see `read`. */
    func indexSpecifier() -> Specifier {
        let index = self.read(self.pop())
        let object = self.pop()
        let container = self.pop()
        return Specifier(kind: .index, object: object, container: container, from: index)
    }

    /**
     `window id 7 of x`, `item named "a" of x`. The key form is a
     constant of the enumeration 'kfrm': 'ID  ' for `id`, 'name' for
     `named`, 'indx' for `index`.
     */
    func keySpecifier() -> Specifier {
        let keyForm = self.pop()
        let key = self.pop()
        let object = self.pop()
        let container = self.pop()
        let form: Code4? = switch (keyForm as? Keyword)?.code {
        case let .four(code)?: code
        case let .eight(code)? where code.first == "kfrm": code.second
        default: nil
        }
        let keyName = switch form {
        case "indx": "index"
        case "name": "named"
        default: "id"
        }
        return Specifier(kind: .key, object: object, container: container, from: key, keyName: keyName)
    }

    /**
     `items 2 thru 4 of x`. The compiler keeps the container twice while
     it works out the ends; a copy that is still there is removed.
     */
    func rangeSpecifier() -> Specifier {
        let to = self.pop()
        let from = self.pop()
        let object = self.pop()
        let container = self.pop()
        if let top = stack.last, top === container {
            _ = self.pop()
        }
        return Specifier(kind: .range, object: object, container: container, from: from, to: to)
    }

    /** `object whose test`. */
    func whoseClause() -> Whose {
        let predicate = self.pop()
        let target = self.pop()
        return Whose(object: target, predicate: predicate)
    }

    /**
     Builds a call from a message send.

     The stack holds, from the bottom: the target, the arguments, and
     the argument count on top. Literal `index` names what is called.
     There are three kinds of call:

     ```
     name(a, b)                       positional: a user handler
     polish of x to y given flag:f    labeled: a user handler, named by a byte string
     display dialog "x" buttons b     a command, named by its event code
     ```

     - `positional`: the instruction says the call is of the first kind.
     */
    func message(_ index: Int, _ positional: Bool) {
        let count = self.popNumber()
        let values: [any Expr?] = self.popMany(count)
        let target = self.pop()
        let stored = self.function.literal(index)
        let name = self.literal(index)
        if positional {
            self.push(self.positionalCall(name, target, values))
        } else if let call = self.labeledCall(stored, name, target, values) {
            self.push(call)
        } else {
            self.push(self.commandCall(stored, name, target, values))
        }
    }

    /** `name(a, b)`, or `target's name(a, b)` when the target is not `it`. */
    func positionalCall(_ name: any Expr, _ target: any Expr, _ values: [any Expr?]) -> HandlerCall {
        let name = (name as? StringLiteral)?.value ?? "handler"
        return HandlerCall(name: name, target: target is It ? nil : target, arguments: values)
    }

    /**
     A call to a user handler with labeled parameters. The target is
     the direct parameter (`it` when there is none), and the values are
     pairs of a label and a value.

     A byte string is the name of a user handler, never an event code,
     also when it is eight letters long (`describe`). Without arguments
     and without a direct parameter, the call is `name()`.

     - Returns: `nil` when the call is not of this kind.
     */
    func labeledCall(_ stored: Value?, _ name: any Expr, _ target: any Expr, _ values: [any Expr?]) -> (any Expr)? {
        guard
            stored?.bytes != nil,
            let text = name as? StringLiteral
        else {
            return nil
        }
        if values.isEmpty, target is It {
            return HandlerCall(name: text.value, arguments: [])
        }
        return values.labeledArguments.map { LabeledCall(name: text.value, direct: target is It ? nil : target, arguments: $0) }
    }

    /**
     A call to a command. The target is the direct argument, unless it
     is `it`. The name comes from the dictionary of the application
     that is told, by the event code.

     Without an event code, the stored name is kept as it is. One name
     is known: `path`, with the keyword `to` before its argument, is
     `path to`.
     */
    func commandCall(_ stored: Value?, _ nameExpr: any Expr, _ target: any Expr, _ values: [any Expr?]) -> CommandCall {
        let values = target is It ? values : [target] + values
        let isUserHandler = stored?.bytes != nil
        let found = isUserHandler ? nil : stored?.eventCode ?? self.eventCode(of: nameExpr)
        var rawName = ""
        if found == nil {
            if let bytes = stored?.bytes, !bytes.isEmpty {
                rawName = String(decoding: bytes, as: UTF8.self)
            }
            if rawName.isEmpty {
                self.decompiler.report(
                    self.function.offset,
                    "cannot recover event code from \(stored.typeName) (literal \(nameExpr.nodeName))",
                )
            }
        }
        let code = found ?? EventCode()
        let command = self.terms?.command(code)
        let isPathTo = rawName == "path"
        let name = isPathTo && values.hasKeyword("to  ") ? "path to" : command?.name ?? rawName
        return CommandCall(code: code, name: name, arguments: (command ?? Command()).arguments(values, toIsDirect: isPathTo))
    }

    /**
     Reads an event code from the literal as an expression, when the
     stored value has none: an 8-letter text, a constant of 8 bytes, or
     raw data that starts with 8 bytes.
     */
    func eventCode(of name: any Expr) -> EventCode? {
        switch name {
        case let value as StringLiteral where value.value.utf8.count == 8:
            EventCode(bytes: Array(value.value.utf8))
        case let value as Keyword:
            if case let .eight(found)? = value.code {
                found
            } else {
                nil
            }
        case let value as RawDataLiteral where value.data.count >= 8:
            EventCode(bytes: value.data)
        default:
            nil
        }
    }

    /**
     Builds a `continue`, which passes a message on to the parent handler.

     The compiler pushes the receiver first (`me`), and a value used only
     at run time (`PushNext`, which pushes nothing here). The two forms
     differ in where the count is:

     ```
     PositionalContinue   me, arguments…, count, (next), it
     Continue             me, label, value, …, count, (next), direct parameter
     ```

     For `Continue`, the count is the number of labels and values, and
     the direct parameter is `it` when there is none. The stack is put
     in the shape `message` expects (direct parameter, labels and
     values, count), and the call it builds is wrapped.

     The result is an expression, because a `continue` can be used for
     its value. When nothing uses it, `emit` turns it into a statement.
     */
    func continueCall(_ index: Int, _ positional: Bool) {
        if positional {
            if !self.stack.isEmpty, self.stack[self.stack.count - 1] is It {
                _ = self.pop()
            }
        } else {
            let direct = self.pop()
            let count = self.popNumber()
            let values = self.popMany(count)
            _ = self.pop() // the receiver, `me`
            self.push(direct)
            for value in values {
                self.push(value)
            }
            self.push(NumberLiteral(integer: Int64(values.count)))
        }
        self.message(index, positional)
        let call = self.pop()
        if let handlerCall = call as? HandlerCall, handlerCall.target is Me {
            handlerCall.target = nil
        }
        self.push(ContinueExpr(call: call))
    }
}

extension BinaryKind {
    /** The operator of the syntax tree for an operator of the bytecode. */
    init(_ op: Operator) {
        self = switch op {
        case .equal: .equal
        case .notEqual: .notEqual
        case .greaterThan: .greater
        case .greaterThanOrEqual: .greaterEqual
        case .lessThan: .less
        case .lessThanOrEqual: .lessEqual
        case .startsWith: .startsWith
        case .endsWith: .endsWith
        case .contains: .contains
        case .add: .add
        case .subtract: .subtract
        case .multiply: .multiply
        case .divide: .divide
        case .quotient: .quotient
        case .remainder: .remainder
        case .power: .power
        case .concatenate: .concatenate
        }
    }
}

extension Expr {
    /**
     The option names of a `considering` block (`case`, `white space`, …),
     when the expression is the keyword, or the list of keywords, that
     the compiler pushes for the block.
     */
    func considerationNames(_ terms: Registry?) -> [String] {
        if let list = self as? List {
            return list.elements.flatMap { $0?.considerationNames(terms) ?? [] }
        }
        guard let keyword = self as? Keyword else {
            return []
        }
        if !keyword.fallback.isEmpty {
            return [keyword.fallback]
        }
        // An option is one four-character code, or the second half of an
        // eight-character one.
        let option: Code4? = switch keyword.code {
        case let .four(code)?: code
        case let .eight(code)?: code.second
        default: nil
        }
        if let option, let name = terms?.languageEnumeration(option) ?? terms?.term(option) ?? terms?.enumeration(option) {
            return [name]
        }
        let bytes = option?.bytes ?? keyword.code?.bytes ?? []
        return bytes.isEmpty ? [] : [String(decoding: bytes, as: UTF8.self)]
    }
}

extension [any Expr?] {
    /**
     The values as the arguments of a call to a user handler with
     labeled parameters. The compiler pushes each one as a label and a
     value:

     ```
     "flag"  true        given flag:true     a word of the script author
     'to  '  5           to 5                a preposition, by its code
     ```

     `nil` when the values are not pairs of that form.
     */
    var labeledArguments: [LabeledArgument]? {
        guard self.count.isMultiple(of: 2) else {
            return nil
        }
        var arguments: [LabeledArgument] = []
        for index in stride(from: 0, to: self.count, by: 2) {
            switch self[index] {
            case let label as StringLiteral:
                arguments.append(LabeledArgument(label: .word(label.value), value: self[index + 1]))
            case let label as Keyword:
                guard case let .four(code)? = label.code else {
                    return nil
                }
                arguments.append(LabeledArgument(label: .code(code), value: self[index + 1]))
            default:
                return nil
            }
        }
        return arguments
    }

    /** True when one of the values is the keyword with this code. */
    func hasKeyword(_ code: Code4) -> Bool {
        self.contains { ($0 as? Keyword)?.code == .four(code) }
    }
}

extension Value {
    /**
     The event code (event class and event ID) inside the value: an
     event identifier, an 8-byte string, or the first one found in a
     vector. `nil` when there is none.
     */
    var eventCode: EventCode? {
        var seen = Visited()
        func find(_ value: Value) -> EventCode? {
            switch value {
            case let .object(content):
                if case let .eventIdentifier(event) = content {
                    return event.code
                }
                return find(content)
            case let .bytes(data):
                return data.count == 8 ? EventCode(bytes: data) : nil
            case let .vector(vector):
                // A vector that holds itself is searched once.
                guard seen.enter(vector) else {
                    return nil
                }
                for child in vector.children.dropFirst(vector.hasType ? 1 : 0) {
                    if let code = find(child) {
                        return code
                    }
                }
                return nil
            default:
                return nil
            }
        }
        return find(self)
    }
}

extension Command {
    /**
     Groups the raw arguments of a call to the command into direct,
     named and flag arguments.

     The compiler pushes a named argument as two values: a four-byte
     keyword (the label) and the value.

     ```
     keyword value   → named argument, or with/without flag for a boolean
     'to  ' value    → direct argument (commands such as "path to")
     value           → direct argument
     ```

     A command that no dictionary has is `Command()`: every label is
     then a named argument without a word.

     - `toIsDirect`: the value after `to` is the direct argument, also
       when the dictionary does not say that the command has one.
     */
    func arguments(_ values: [any Expr?], toIsDirect: Bool = false) -> [any Argument] {
        var output: [any Argument] = []
        var index = 0
        while index < values.count {
            defer { index += 1 }
            guard
                let keyword = values[index] as? Keyword,
                case let .four(code)? = keyword.code,
                index + 1 < values.count
            else {
                output.append(DirectArgument(value: values[index]))
                continue
            }
            let value = values[index + 1]
            index += 1
            let parameter = self.parameters[code]
            // The compiler uses the internal keyword "to  " to delimit the
            // direct argument of commands such as Standard Additions' “path to”.
            // `random number from 1 to 10` has a parameter named `to`: it is not this one.
            if code == "to  ", parameter == nil, self.hasDirectParameter || toIsDirect {
                output.append(DirectArgument(value: value))
            } else if let boolean = value as? BooleanLiteral, let parameter, parameter.type == "boolean" {
                output.append(FlagArgument(code: code, name: parameter.name, enabled: boolean.value))
            } else {
                output.append(NamedArgument(code: code, name: parameter?.name ?? "", value: value))
            }
        }
        return output
    }
}
