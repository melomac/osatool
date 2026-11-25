import Extensions
import Terminology

// MARK: Literals

package final class StringLiteral: Expr {
    package var value: String

    package init(value: String = "") {
        self.value = value
    }
}

/** An integer, or a real when `isReal` is true. */
package final class NumberLiteral: Expr {
    package var integer: Int64
    package var real: Double
    package var isReal: Bool

    package init(integer: Int64 = 0, real: Double = 0, isReal: Bool = false) {
        self.integer = integer
        self.real = real
        self.isReal = isReal
    }
}

package final class BooleanLiteral: Expr {
    package var value: Bool

    package init(value: Bool = false) {
        self.value = value
    }
}

package final class MissingLiteral: Expr {
    package init() {}
}

package final class DateLiteral: Expr {
    package var value: String

    package init(value: String = "") {
        self.value = value
    }
}

/** Typed raw bytes, printed as `«data TYPEhex…»`. */
package final class RawDataLiteral: Expr {
    package var type: Code4
    package var data: [UInt8]

    package init(type: Code4 = Code4(), data: [UInt8] = []) {
        self.type = type
        self.data = data
    }
}

/**
 A runtime class and its bytes, when their meaning in source code is not
 known. It is printed as an explicit "unsupported" form on purpose.
 */
package final class OpaqueLiteral: Expr {
    package var runtimeType: UInt8
    package var data: [UInt8]

    package init(runtimeType: UInt8 = 0, data: [UInt8] = []) {
        self.runtimeType = runtimeType
        self.data = data
    }
}

/**
 The code of a keyword, as the script stores it:

 ```
 four    a class, a property or another term           'pnam'
 eight   an enumeration and its member, or an event    'savo' 'yes '
 other   another number of bytes: a damaged code
 ```
 */
package enum KeywordCode: Hashable, Sendable {
    case four(Code4)
    case eight(EventCode)
    case other([UInt8])

    /** Creates the code for some bytes. There is no code for no bytes. */
    package init?(bytes: [UInt8]) {
        switch bytes.count {
        case 0:
            return nil
        case 4:
            self = .four(Code4(bytes: bytes))
        case 8:
            self = .eight(EventCode(bytes: bytes))
        default:
            self = .other(bytes)
        }
    }

    /**
     Creates the code held by a stored constant: one number, with the
     first character in the highest byte.

     A number that fits in four bytes is a four-character code. A larger
     number takes the bytes it needs, up to eight:

     ```
     0x0000_0000_706e_616d   →  four    'pnam'
     0x7361_766f_7965_7320   →  eight   'savo' 'yes '
     0x0000_0041_4243_4445   →  other   41 42 43 44 45
     ```
     */
    package init(packed value: UInt64) {
        var width = 4
        while width < 8, value >> (8 * UInt64(width)) != 0 {
            width += 1
        }
        let bytes = (0 ..< width).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(width - 1 - $0))) }
        self = KeywordCode(bytes: bytes) ?? .four(Code4())
    }

    /** The bytes of the code. */
    package var bytes: [UInt8] {
        switch self {
        case let .four(code): code.bytes
        case let .eight(code): code.bytes
        case let .other(bytes): bytes
        }
    }
}

/**
 A term given by its code.

 When `fallback` is not empty it is printed as is. If not, the formatter
 looks the code up in the terminology. A keyword can also have a
 `fallback` and no code, for a fixed text such as `current application`.
 */
package final class Keyword: Expr {
    package var code: KeywordCode?
    package var fallback: String

    package init(code: KeywordCode? = nil, fallback: String = "") {
        self.code = code
        self.fallback = fallback
    }
}

package final class Variable: Expr {
    package var name: String

    package init(name: String = "") {
        self.name = name
    }
}

package final class Application: Expr {
    package var name: String

    package init(name: String = "") {
        self.name = name
    }
}

package extension Expr {
    /**
     The application this expression names with a text of the script,
     or `nil`:

     ```
     application "Finder"
     application "/System/Library/CoreServices/Finder.app"
     application id "com.apple.finder"
     ```

     The compiler stores the first form as one value, and the two
     others as `application "…" of me`. The source has no `of me`
     there. With a variable, as in `application x`, the compiler does
     not know the application, and the result is `nil`.
     */
    var applicationName: ApplicationName? {
        if let application = self as? Application {
            return .name(application.name)
        }
        guard
            let node = self as? Specifier,
            node.container is Me,
            let keyword = node.object as? Keyword,
            keyword.code == .four("capp"),
            let text = (node.from as? StringLiteral)?.value
        else {
            return nil
        }
        switch (node.kind, node.keyName) {
        case (.index, _), (.key, "named"):
            return .name(text)
        case (.key, "id"), (.key, ""):
            return .identifier(text)
        default:
            return nil
        }
    }
}

package final class ScriptLibrary: Expr {
    package var name: String

    package init(name: String = "") {
        self.name = name
    }
}

package final class Me: Expr {
    package init() {}
}

package final class It: Expr {
    package init() {}
}

/**
 `current application`: the application that runs the script. The
 compiler stores it as the constant 'misc' 'cura'.
 */
package final class CurrentApplication: Expr {
    package init() {}
}

package final class List: Expr {
    package var elements: [any Expr?]

    package init(elements: [any Expr?] = []) {
        self.elements = elements
    }
}

package struct RecordField {
    package var label: any Expr?
    package var value: any Expr?

    package init(label: any Expr? = nil, value: any Expr? = nil) {
        self.label = label
        self.value = value
    }
}

package final class Record: Expr {
    package var fields: [RecordField]

    package init(fields: [RecordField] = []) {
        self.fields = fields
    }
}

// MARK: - Operators

package enum UnaryKind: String, Sendable {
    case not
    case negate = "-"
}

package final class Unary: Expr {
    package var op: UnaryKind
    package var value: any Expr?

    package init(op: UnaryKind, value: any Expr? = nil) {
        self.op = op
        self.value = value
    }
}

/** A binary operator. The raw value is the text printed in the source. */
package enum BinaryKind: String, Sendable {
    case equal = "="
    case notEqual = "≠"
    case greater = ">"
    case greaterEqual = "≥"
    case less = "<"
    case lessEqual = "≤"
    case startsWith = "starts with"
    case endsWith = "ends with"
    case contains
    case and
    case or
    case add = "+"
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case quotient = "div"
    case remainder = "mod"
    case power = "^"
    case concatenate = "&"
    case of
}

package final class Binary: Expr {
    package var op: BinaryKind
    package var left: any Expr?
    package var right: any Expr?

    package init(op: BinaryKind, left: any Expr? = nil, right: any Expr? = nil) {
        self.op = op
        self.left = left
        self.right = right
    }
}

/** `value as type`. */
package final class Coerce: Expr {
    package var value: any Expr?
    package var type: any Expr?

    package init(value: any Expr? = nil, type: any Expr? = nil) {
        self.value = value
        self.type = type
    }
}

/**
 `get value`: the object a reference points at, read at once.

 ```
 countThem(every item of desktop)        the handler receives a reference
 countThem(get every item of desktop)    the handler receives a list
 ```

 `get` leaves a trace only for a reference, and only where the compiler
 does not read the value by itself (see `State.read`).
 */
package final class GetExpr: Expr {
    package var value: any Expr?

    package init(value: any Expr? = nil) {
        self.value = value
    }
}

/** `a reference to value`. */
package final class Reference: Expr {
    package var value: any Expr?

    package init(value: any Expr? = nil) {
        self.value = value
    }
}

/**
 A copy of a value, as `copy value to x` makes one before it stores it.

 The decompiler finds it on the stack between the instruction that
 copies and the one that stores, and makes the statement `Copy` from
 it. The language has no expression for it: in a tree read from good
 bytecode there is none left.
 */
package final class CopyExpr: Expr {
    package var value: any Expr?

    package init(value: any Expr? = nil) {
        self.value = value
    }
}

// MARK: - Calls

/** One argument of a command call. */
package protocol Argument {}

/** The direct (unnamed) argument: `open theFile`. */
package struct DirectArgument: Argument {
    package var value: any Expr?

    package init(value: any Expr? = nil) {
        self.value = value
    }
}

/** A labeled argument: `with prompt "…"`. */
package struct NamedArgument: Argument {
    package var code: Code4
    package var name: String
    package var value: any Expr?

    package init(code: Code4 = Code4(), name: String = "", value: any Expr? = nil) {
        self.code = code
        self.name = name
        self.value = value
    }
}

/** A boolean argument written as `with name` or `without name`. */
package struct FlagArgument: Argument {
    package var code: Code4
    package var name: String
    package var enabled: Bool

    package init(code: Code4 = Code4(), name: String = "", enabled: Bool = false) {
        self.code = code
        self.name = name
        self.enabled = enabled
    }
}

/** A call to a command defined by terminology (an Apple event). */
package final class CommandCall: Expr {
    package var code: EventCode
    package var name: String
    package var target: any Expr?
    package var arguments: [any Argument]

    package init(code: EventCode = EventCode(), name: String = "", target: any Expr? = nil, arguments: [any Argument] = []) {
        self.code = code
        self.name = name
        self.target = target
        self.arguments = arguments
    }
}

/** One labeled argument of a `LabeledCall`. */
package struct LabeledArgument {
    package var label: Label
    package var value: any Expr?

    package init(label: Label, value: any Expr? = nil) {
        self.label = label
        self.value = value
    }
}

/**
 A call to a user handler that has labeled parameters:

 ```
 findNumbers of numberList above 1 given rounding:true
             └─ direct ──┘ └─ arguments ─────────────┘
 ```

 A handler of another object is called with a `tell` block around the
 call, so there is no target here.
 */
package final class LabeledCall: Expr {
    package var name: String
    package var direct: any Expr?
    package var arguments: [LabeledArgument]

    package init(name: String = "", direct: any Expr? = nil, arguments: [LabeledArgument] = []) {
        self.name = name
        self.direct = direct
        self.arguments = arguments
    }
}

/** A call to a user handler: `name(a, b)`. */
package final class HandlerCall: Expr {
    package var name: String
    package var target: any Expr?
    package var arguments: [any Expr?]

    package init(name: String = "", target: any Expr? = nil, arguments: [any Expr?] = []) {
        self.name = name
        self.target = target
        self.arguments = arguments
    }
}

// MARK: - Object specifiers

package enum SpecifierKind: String, Sendable {
    case property
    case every
    case some
    case index
    case key
    case range
    case beginning
    case end
    case middle
    /** `object before container`, also written `in front of`. */
    case before
    /** `object after container`, also written `behind`. */
    case after
}

/**
 An object specifier: `object … of container`.

 Which fields are used depends on `kind`:

 ```
 property    object of container
 every       every object of container
 index       object from of container            (item 3 of x)
 key         object keyName from of container    (window id 7 of x)
 range       object from thru to of container    (items 1 thru 3 of x)
 beginning   beginning of container
 before      object before container             (window before window 2)
 ```
 */
package final class Specifier: Expr {
    package var kind: SpecifierKind
    package var object: any Expr?
    package var container: any Expr?
    package var from: any Expr?
    package var to: any Expr?
    package var keyName: String

    package init(
        kind: SpecifierKind, object: any Expr? = nil, container: any Expr? = nil,
        from: any Expr? = nil, to: any Expr? = nil, keyName: String = "",
    ) {
        self.kind = kind
        self.object = object
        self.container = container
        self.from = from
        self.to = to
        self.keyName = keyName
    }
}

/** `object whose predicate`. */
package final class Whose: Expr {
    package var object: any Expr?
    package var predicate: any Expr?

    package init(object: any Expr? = nil, predicate: any Expr? = nil) {
        self.object = object
        self.predicate = predicate
    }
}

package final class ScriptObject: Expr {
    package var name: String
    /** The declarations of the script object, in the order of the source. */
    package var members: [Member]

    package var properties: [Property] {
        get { self.members.compactMap(\.property) }
        set { self.members.replace(newValue, \.property, Member.property) }
    }

    /** The script objects defined inside this one. */
    package var objects: [ScriptObject] {
        get { self.members.compactMap(\.object) }
        set { self.members.replace(newValue, \.object, Member.object) }
    }

    package var handlers: [Handler] {
        get { self.members.compactMap(\.handler) }
        set { self.members.replace(newValue, \.handler, Member.handler) }
    }

    package init(
        name: String = "", properties: [Property] = [], objects: [ScriptObject] = [],
        handlers: [Handler] = [],
    ) {
        self.name = name
        self.members = properties.map(Member.property) + objects.map(Member.object) + handlers.map(Member.handler)
    }
}

/**
 `continue call`, used for its result: `"<" & (continue label(x)) & ">"`.

 A `continue` that stands alone is the statement `Continue`.
 */
package final class ContinueExpr: Expr {
    package var call: any Expr?

    package init(call: any Expr? = nil) {
        self.call = call
    }
}
