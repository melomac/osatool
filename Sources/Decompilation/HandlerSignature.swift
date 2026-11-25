import AST
import Extensions
import FAS
import Model
import Terminology

extension Value {
    /**
     The keyword that names a property, when the name is stored as a
     code and not as a word of the script author:

     ```
     property size : 3      the name is the code 'ptsz'
     ```
     */
    var propertyKeyword: Keyword? {
        guard
            case .object(.constant) = self,
            let keyword = self.literal as? Keyword,
            keyword.code != nil
        else {
            return nil
        }
        return keyword
    }

    /** True when the value is an object holding the four-character code `code`. */
    func isConstant(_ code: Code4) -> Bool {
        guard case let .object(.constant(constant)) = self else {
            return false
        }
        return Code4(rawValue: UInt32(truncatingIfNeeded: constant)) == code
    }

    /**
     Reads the value as the name of a function.

     - A byte string is a user handler name.
     - An event identifier is an event handler: `run` for `aevt/oapp`, the
       command name when the terminology knows the event, or `event_<hex>`.
     */
    func functionName(_ terms: Registry?) -> (name: String, event: EventCode?, isRun: Bool) {
        if let bytes = self.bytes {
            return (String(decoding: bytes, as: UTF8.self), nil, false)
        }
        if case let .object(.eventIdentifier(event)) = self {
            let code = event.code
            if code == "aevtoapp" {
                return ("run", code, true)
            }
            if let command = terms?.commandAnywhere(code) {
                return (command.name, code, false)
            }
            return ("event_" + code.bytes.hex, code, false)
        }
        return ("handler", nil, false)
    }
}

extension Label {
    /**
     Reads a stored label: a byte string is a word of the script author, a
     four-character code is a word of the language or of a command.
     */
    init(stored value: Value) {
        if case let .object(.constant(constant)) = value, constant <= 0xffff_ffff {
            self = .code(Code4(rawValue: UInt32(constant)))
        } else if let bytes = value.bytes {
            self = .word(String(decoding: bytes, as: UTF8.self))
        } else {
            self = .word(value.identifier(or: "label"))
        }
    }
}

/**
 The shape of a handler parameter, as the compiler stores it:

 ```
 a byte string            a name                  x
 a vector of class 4      a list of patterns      {a, b}
 a chain of bindings      a record of patterns    {x:a, y:b}
 ```

 The positional parameters of a user handler are stored as one list:
 `on mix(a, b)` has the same pattern as `on run {a, b}`.
 */
indirect enum ParameterPattern {
    case name(Value)
    case list([ParameterPattern])
    case record([(label: Value, pattern: ParameterPattern)])

    /** The number of names in the pattern. */
    var nameCount: Int {
        switch self {
        case .name:
            1
        case let .list(items):
            items.reduce(0) { $0 + $1.nameCount }
        case let .record(fields):
            fields.reduce(0) { $0 + $1.pattern.nameCount }
        }
    }

    /**
     Turns the pattern into an expression: a variable, a list or a
     record. Each name of the pattern takes the next name of `names`.
     */
    func expr(_ names: inout ParameterNames) -> any Expr {
        switch self {
        case .name:
            Variable(name: names.next())
        case let .list(items):
            List(elements: items.map { $0.expr(&names) })
        case let .record(fields):
            Record(fields: fields.map { RecordField(label: $0.label.literal, value: $0.pattern.expr(&names)) })
        }
    }
}

/**
 Gives the names of the parameters of a handler, in order.

 The parameters are the first variables of the function, in the order
 of the header. The names come from the list of variables, so that the
 header and the body of the handler use the same names.
 */
struct ParameterNames {
    var variables: [String]
    var index = 0

    mutating func next() -> String {
        defer { index += 1 }
        return self.index < self.variables.count ? self.variables[self.index] : "arg_\(self.index)"
    }
}

/**
 Reads stored parameter patterns.

 A damaged or hostile file can share one vector many times, or put a
 vector inside itself. Two limits make sure the work ends: `budget` is
 the number of values that can still be read, and `maxDepth` is how
 deep a pattern can be inside another one. A value over a limit is
 read as a plain name.
 */
struct ParameterReader {
    var budget = 4096
    static let maxDepth = 32

    /**
     Reads one pattern.

     - Returns: `nil` when there is no parameter: nothing, the stored
       nil, or an empty list cell.
     */
    mutating func pattern(_ value: Value, depth: Int = 0) -> ParameterPattern? {
        self.budget -= 1
        if self.budget < 0 || depth > Self.maxDepth {
            return .name(value)
        }
        switch value {
        case .null:
            return nil
        case let .pair(pair) where pair.empty:
            return nil
        case let .binding(binding) where binding.empty:
            return nil
        case let .vector(vector):
            guard
                vector.children.count > 2,
                let nested = vector.children[2].vector
            else {
                return .name(value)
            }
            return .list(nested.children.dropFirst(nested.hasType ? 1 : 0).map { self.pattern($0, depth: depth + 1) ?? .name($0) })
        case .binding:
            return .record(self.fields(value, depth: depth + 1))
        default:
            return .name(value)
        }
    }

    /**
     Reads a chain of bindings: the fields of a record pattern, or the
     labeled parameters of a handler. Each binding gives a label and
     the pattern that receives the value.
     */
    mutating func fields(_ value: Value, depth: Int = 0) -> [(label: Value, pattern: ParameterPattern)] {
        var fields: [(label: Value, pattern: ParameterPattern)] = []
        var seen = Visited()
        var current = value.binding
        while let cell = current, !cell.empty, self.budget > 0, seen.enter(cell) {
            fields.append((cell.key, self.pattern(cell.value, depth: depth) ?? .name(cell.value)))
            current = cell.next.binding
        }
        return fields
    }
}

/**
 The parameters of a function, as stored: the direct parameter and the
 labeled ones (see `Function`).
 */
struct StoredParameters {
    var direct: ParameterPattern?
    var labeled: [(label: Value, pattern: ParameterPattern)]

    init(_ function: Function) {
        var reader = ParameterReader()
        self.direct = reader.pattern(function.arguments)
        self.labeled = reader.fields(function.labels)
    }

    /** The number of variables of the function that are parameters. */
    var nameCount: Int {
        (self.direct?.nameCount ?? 0) + self.labeled.reduce(0) { $0 + $1.pattern.nameCount }
    }

    /**
     Returns the parameters of the handler header.

     - `isUserHandler`: the handler has a name, not an event code. Its
       list pattern, when no parameter has a label, is the list of the
       positional parameters: `on mix(a, b)`. In every other case the
       pattern is one direct parameter: `on run {a, b}`.
     - `variables`: the names of the variables of the function.
     */
    func parameters(isUserHandler: Bool, variables: [String]) -> [Parameter] {
        var names = ParameterNames(variables: variables)
        var parameters: [Parameter] = []
        if isUserHandler, self.labeled.isEmpty, case let .list(items)? = direct {
            parameters = items.map { Parameter(receiver: $0.expr(&names)) }
        } else if let direct {
            parameters.append(Parameter(receiver: direct.expr(&names)))
        }
        for item in self.labeled {
            parameters.append(Parameter(receiver: item.pattern.expr(&names), label: Label(stored: item.label)))
        }
        return parameters
    }
}

extension Parameter {
    /** Creates a parameter from what receives it: a variable, or a pattern. */
    init(receiver: any Expr, label: Label? = nil) {
        if let variable = receiver as? Variable {
            self.init(name: variable.name, label: label)
        } else {
            self.init(pattern: receiver, label: label)
        }
    }
}
