import Extensions

/**
 A node in the object graph stored in a compiled script.

 A `.scpt` file is a dump of AppleScript runtime objects. The parser reads
 it into a graph of values:

 ```
 vector ──┬── bytes        (a name)
          ├── vector ──┬── object ── constant
          │            └── pair ── pair ── …    (a list)
          └── bytes        (bytecode)
 ```

 A small value holds its content in the case itself. The four containers
 (`pair`, `binding`, `vector`, `statement`) are classes, because the graph
 can share a container, and can even contain loops: two values are the
 same container when they hold the same class instance.

 Two values are equal when they have the same case and the same content.
 For a container, "the same content" means the same class instance.

 An optional `Value?` that is `nil` means "there is no value here": an
 index out of range, or a property the script does not have. It is not
 the same as `.null`, which is a real stored object.
 */
package enum Value: Equatable {
    /** The stored "nil" object. */
    case null
    case boolean(Bool)
    case integer(Int64)
    /** A 64-bit floating point number. */
    case real(Double)
    /** A runtime special value such as true or false: see `Special`. */
    case special(UInt64)
    /**
     A packed code: four bytes (`'pnam'`) or eight bytes (class and
     member), stored as one number with the first character in the
     highest byte.
     */
    case constant(UInt64)
    /** A marker object the runtime uses for a second actor. */
    case secondActor
    /** A raw byte string: a name, a classic string, or a block of bytecode. */
    case bytes([UInt8])
    case unicodeText(UnicodeText)
    case rawData([UInt8])
    case typedData(TypedData)
    case descriptor(Descriptor)
    case eventIdentifier(EventIdentifier)
    /** A wrapper that marks its content as a script-level object. */
    indirect case object(Value)
    case pair(Pair)
    case binding(Binding)
    case vector(Vector)
    case statement(Statement)
}

/** The numbers of the runtime special values. */
package enum Special {
    package static let `nil`: UInt64 = 0
    package static let `false`: UInt64 = 0x79
    package static let `true`: UInt64 = 0x7a
}

/**
 Stored text. With a style table it is styled text, as old versions of
 Script Editor wrote it: the bytes are MacRoman. Without one the bytes
 are UTF-16 big-endian.
 */
package struct UnicodeText: Equatable {
    package var text: [UInt8]
    package var style: [UInt8]

    package init(text: [UInt8] = [], style: [UInt8] = []) {
        self.text = text
        self.style = style
    }
}

/**
 Data of a runtime class the decompiler does not understand.

 AppleScript's loader accepts data blocks for more classes than the small
 set this tool can decode. Keeping the class index and the bytes is safer
 than rejecting the file or guessing a wrong meaning.
 */
package struct TypedData: Equatable {
    package var type: UInt8
    package var data: [UInt8]

    package init(type: UInt8 = 0, data: [UInt8] = []) {
        self.type = type
        self.data = data
    }
}

/** An Apple event descriptor: a four-byte type and its content. */
package struct Descriptor: Equatable {
    package var type: Code4
    package var content: [UInt8]

    package init(type: Code4 = Code4(), content: [UInt8] = []) {
        self.type = type
        self.content = content
    }
}

/**
 The identifier of an Apple event: six four-byte fields.

 Field 0 is the event class and field 1 is the event ID.
 */
package struct EventIdentifier: Equatable {
    /** Always six fields. */
    package var fields: [Code4]

    package init(fields: [Code4] = Array(repeating: Code4(), count: 6)) {
        self.fields = fields
    }

    /** The event class and the event ID, as one code. */
    package var code: EventCode {
        EventCode(first: self.fields[0], second: self.fields[1])
    }

    /**
     True when the source named the event by its code, `«event
     emalcpma»`, and not by a word of a dictionary. The four other
     fields describe the command as its dictionary does. With no
     dictionary the compiler writes the same values every time:

     ```
     «event emalcpma»                    '****' 0          '****' 0x9000
     perform mail action with messages   'null' 0xffff8000 '****' 0
     ```
     */
    package var isRawForm: Bool {
        self.fields.count == 6 && self.fields[2] == "****" && self.fields[3].rawValue == 0
            && self.fields[4] == "****" && self.fields[5].rawValue == 0x9000
    }
}

/**
 A container of the graph. It is a class, and two containers are equal
 only when they are the same instance.
 */
package protocol Container: AnyObject, Equatable {}

package extension Container {
    static func == (left: Self, right: Self) -> Bool {
        left === right
    }
}

/**
 One cell of a linked list: `head` is the item, `tail` is the rest.

 A list of a million items is a chain of a million cells. When nothing
 uses the list any more, Swift frees the first cell, which frees the
 second one from inside, and so on: one call inside the other for each
 cell, until the stack is full. So a cell that goes away takes the rest
 of its chain apart in a loop.
 */
package final class Pair: Container {
    package var empty: Bool
    package var head: Value
    package var tail: Value

    package init(empty: Bool = false, head: Value = .null, tail: Value = .null) {
        self.empty = empty
        self.head = head
        self.tail = tail
    }

    deinit {
        var next = self.tail.pair
        self.tail = .null
        // A cell that something else still uses stays as it is.
        while next != nil, isKnownUniquelyReferenced(&next) {
            let following = next?.tail.pair
            next?.tail = .null
            next = following
        }
    }
}

/**
 One field of a record: `key`, `value`, and `next` for the rest. Like a
 cell of a list, a binding that goes away takes the rest of its chain
 apart in a loop.
 */
package final class Binding: Container {
    package var empty: Bool
    package var key: Value
    package var value: Value
    package var extra: Value
    package var next: Value

    package init(empty: Bool = false, key: Value = .null, value: Value = .null, extra: Value = .null, next: Value = .null) {
        self.empty = empty
        self.key = key
        self.value = value
        self.extra = extra
        self.next = next
    }

    deinit {
        var next = self.next.binding
        self.next = .null
        while next != nil, isKnownUniquelyReferenced(&next) {
            let following = next?.next.binding
            next?.next = .null
            next = following
        }
    }
}

/**
 An array of values.

 When `hasType` is true the vector is a typed runtime object: `type` is its
 class index and `children[0]` is an unused slot, so the real items start
 at index 1.
 */
package final class Vector: Container {
    package var type: UInt8
    package var hasType: Bool {
        didSet { self.keptItems = nil }
    }

    package var children: [Value] {
        didSet { self.keptItems = nil }
    }

    /** The result of `items`, kept until the vector changes. */
    private var keptItems: [Value]?

    package init(type: UInt8 = 0, hasType: Bool = false, children: [Value] = []) {
        self.type = type
        self.hasType = hasType
        self.children = children
    }

    /**
     The real items of the vector: a typed vector skips its slot 0.

     The array is made once and kept. Many handlers can share one
     vector of names or of literals, and each one asks for its items: a
     new copy for each would cost the size of the vector every time.
     */
    package var items: [Value] {
        if !self.hasType {
            return self.children
        }
        if let kept = self.keptItems {
            return kept
        }
        let items = self.children.count <= 1 ? [] : Array(self.children[1...])
        self.keptItems = items
        return items
    }

    /** The number of items, without making the array. */
    package var itemCount: Int {
        self.hasType ? max(self.children.count - 1, 0) : self.children.count
    }
}

/** A source statement record kept by scripts that are not run-only. */
package final class Statement: Container {
    package var tag: UInt8
    package var typeInfo: UInt16
    package var start: UInt16
    package var end: UInt16
    package var children: [Value]

    package init(tag: UInt8 = 0, typeInfo: UInt16 = 0, start: UInt16 = 0, end: UInt16 = 0, children: [Value] = []) {
        self.tag = tag
        self.typeInfo = typeInfo
        self.start = start
        self.end = end
        self.children = children
    }
}

// MARK: - Reading one case

package extension Value {
    var isNull: Bool {
        self == .null
    }

    /** The bytes of a byte string, or `nil` for another value. */
    var bytes: [UInt8]? {
        if case let .bytes(data) = self {
            data
        } else {
            nil
        }
    }

    /** The code of a constant that is not inside an object, or `nil`. */
    var constant: UInt64? {
        if case let .constant(code) = self {
            code
        } else {
            nil
        }
    }

    /** The content of an object wrapper, or `nil` for another value. */
    var object: Value? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }

    var pair: Pair? {
        if case let .pair(pair) = self {
            pair
        } else {
            nil
        }
    }

    var binding: Binding? {
        if case let .binding(binding) = self {
            binding
        } else {
            nil
        }
    }

    var vector: Vector? {
        if case let .vector(vector) = self {
            vector
        } else {
            nil
        }
    }

    /**
     A short, stable name for the kind of the value, for messages:
     `vector`, `bytes`, `unicode-text`, …
     */
    var typeName: String {
        switch self {
        case .null: "nil"
        case .boolean: "bool"
        case .integer: "integer"
        case .real: "float"
        case .bytes: "bytes"
        case .unicodeText: "unicode-text"
        case .special: "special"
        case .constant: "constant"
        case .object: "object"
        case .rawData: "raw-data"
        case .typedData: "typed-data"
        case .descriptor: "descriptor"
        case .eventIdentifier: "event-identifier"
        case .pair: "pair"
        case .binding: "binding"
        case .vector: "vector"
        case .statement: "statement"
        case .secondActor: "second-actor"
        }
    }
}

package extension Value? {
    /** `Value.typeName`, or `nothing` when there is no value. */
    var typeName: String {
        self?.typeName ?? "nothing"
    }
}

// MARK: - Walking the graph

package extension Value {
    /**
     The class instance behind a container, or `nil` for a value that
     is not a container.
     */
    var node: AnyObject? {
        switch self {
        case let .pair(pair): pair
        case let .binding(binding): binding
        case let .vector(vector): vector
        case let .statement(statement): statement
        default: nil
        }
    }

    /**
     The values directly inside this one, in order, each with the name
     of its place:

     ```
     object      object
     pair        head, tail
     binding     key, value, extra, next
     vector      vector[0], vector[1], …
     statement   statement[0], statement[1], …
     ```
     */
    var children: [(place: String, value: Value)] {
        switch self {
        case let .object(value):
            [("object", value)]
        case let .pair(pair):
            [("head", pair.head), ("tail", pair.tail)]
        case let .binding(binding):
            [("key", binding.key), ("value", binding.value), ("extra", binding.extra), ("next", binding.next)]
        case let .vector(vector):
            vector.children.enumerated().map { ("vector[\($0.offset)]", $0.element) }
        case let .statement(statement):
            statement.children.enumerated().map { ("statement[\($0.offset)]", $0.element) }
        default:
            []
        }
    }
}

package extension Value {
    /**
     Adds the containers directly inside this value to `list`, from the
     last to the first. A walk that keeps the values still to visit in a
     list, and takes the last one each time, visits them in order, and
     does not call itself: a long list does not use the stack.

     - `alsoData`: add the blocks of raw data too, for a walk that looks
       for one.
     */
    func appendChildren(to list: inout [Value], alsoData: Bool = false) {
        func isWanted(_ value: Value) -> Bool {
            if case .rawData = value {
                return alsoData
            }
            return value.hasChildren
        }
        switch self {
        case let .object(value):
            list.append(value)
        case let .pair(pair):
            list.append(pair.tail)
            list.append(pair.head)
        case let .binding(binding):
            list.append(binding.next)
            list.append(binding.extra)
            list.append(binding.value)
            list.append(binding.key)
        case let .vector(vector):
            list.append(contentsOf: vector.children.reversed().lazy.filter(isWanted))
        case let .statement(statement):
            list.append(contentsOf: statement.children.reversed().lazy.filter(isWanted))
        default:
            break
        }
    }

    /** True for a value that can have other values inside it: see `children`. */
    var hasChildren: Bool {
        switch self {
        case .object, .pair, .binding, .vector, .statement: true
        default: false
        }
    }
}

/**
 The containers that a walk of the graph is inside of, or has been in.

 The graph can share a container and can contain loops, so every walk
 must know where it has been:

 ```
 vector ──▶ pair ──▶ vector (the same one)
 ```

 A walk that visits each container once calls `enter` and stops when it
 returns `false`. A walk that only must not loop also calls `leave` on
 the way back, so that a container reached again by another path is
 entered again.

 A value that is not a container can always be entered.
 */
package struct Visited {
    private var nodes: Set<ObjectIdentifier> = []

    package init() {}

    /** Notes a container. Returns `false` when it was noted before. */
    @discardableResult
    package mutating func enter(_ node: AnyObject) -> Bool {
        self.nodes.insert(ObjectIdentifier(node)).inserted
    }

    /** Notes a value when it is a container. Returns `false` when it was noted before. */
    @discardableResult
    package mutating func enter(_ value: Value) -> Bool {
        value.node.map { self.enter($0) } ?? true
    }

    /** Forgets a value that was entered. */
    package mutating func leave(_ value: Value) {
        if let node = value.node {
            self.nodes.remove(ObjectIdentifier(node))
        }
    }

    package func contains(_ node: AnyObject) -> Bool {
        self.nodes.contains(ObjectIdentifier(node))
    }
}
