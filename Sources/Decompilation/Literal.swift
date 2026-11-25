import AST
import Extensions
import FAS
import Model
import Terminology

extension Value {
    /**
     The expression that would produce the stored value.

     ```
     null, no value         missing value
     boolean, special       true / false
     integer, real          number
     bytes, unicodeText     "text"
     constant               a keyword, by its code
     pair chain             {a, b, c}
     binding chain          {k:v, …}
     descriptor             a date, an application, or «data …»
     vector                 depends on its runtime class (see `LiteralPath`)
     ```

     This is a conversion on its own, for a label or a name: what it
     can print again is small (see `LiteralPath`). The values of a
     script are converted by `Decompiler.literal`, with one budget for
     the whole script.
     */
    var literal: any Expr {
        var path = LiteralPath(budget: 1024, byteBudget: 65536)
        return path.literal(self)
    }

    /**
     Returns the identifier stored in the value, or `fallback`.

     - A byte string is used when it can be a name (see `String.isName`).
     - A code is used when it prints as a fixed word such as `name`.
     */
    func identifier(or fallback: String) -> String {
        switch self {
        case let .bytes(data):
            let text = String(decoding: data, as: UTF8.self)
            if text.isName {
                return text
            }
        case let .object(.constant(code)):
            // Only a code can be a word: no other value is converted for a name.
            if let keyword = KeywordCode(packed: code).literal as? Keyword, keyword.fallback.isPlainIdentifier {
                return keyword.fallback
            }
        default:
            break
        }
        return fallback
    }
}

extension Value? {
    /** `Value.literal`, or `missing value` when there is no value. */
    var literal: any Expr {
        self?.literal ?? MissingLiteral()
    }

    /** `Value.identifier(or:)`, or `fallback` when there is no value. */
    func identifier(or fallback: String) -> String {
        self?.identifier(or: fallback) ?? fallback
    }
}

/**
 Converts stored values into expressions, and remembers where it is
 inside the object graph: the containers it is inside of, and how deep.

 A damaged or hostile file can hold a value that contains itself:

 ```
 binding ── key ──▶ vector ── child ──▶ (the same binding)
 ```

 Without a guard the conversion never ends and the stack overflows.
 With this record,
 a container met a second time on the same path prints as
 `«cyclic reference»`, and a value nested deeper than `maxDepth`
 prints as `«nesting too deep»`.

 A file can also use one small container many times, with no loop:

 ```
 a = {b, b}     b = {c, c}     c = {d, d}     …
 ```

 Written in full, `a` doubles at each level: 40 levels are a million
 million items. And code can use one long text in every statement: a
 megabyte of text and a thousand statements are a gigabyte.

 So the conversion counts what it writes **again**. The first time a
 list, a record, a text or a block of data is converted, it is written
 in full, whatever its size: all the first times together are not more
 than the file. A value that was converted before, and all that is in
 it, takes from two budgets:

 ```
 budget        the values that can still be written again
 byteBudget    the bytes of text and data that can still be written again
 ```

 When a budget is used up, a small value is still written again: up to
 `smallNodes` values, and a text up to `smallBytes`. A larger one
 prints as `«value too large»`, and a long text as its first
 characters, like `«long text, 1000000 bytes: "curl -s https://…"»`.

 So nothing can be hidden behind a large value. Whatever a file does
 to use up the budgets, a value that comes after is written in full
 its first time, and a short one every time.

 Several conversions share the budgets when they use the same path.
 */
struct LiteralPath {
    /** The deepest nesting of values that the conversion follows. */
    static let maxDepth = 128

    /** The number of values that one decompilation writes again, at most. */
    static let maxNodes = 1 << 22

    /** The number of bytes of text and data that one decompilation writes again, at most. */
    static let maxBytes = 1 << 26

    /** What is still written again when a budget is used up: a value of so many values, a text of so many bytes. */
    static let smallNodes = 8
    static let smallBytes = 256

    var visiting = Visited()
    var depth = 0
    var budget = LiteralPath.maxNodes
    var byteBudget = LiteralPath.maxBytes
    /** The lists, records and vectors converted so far. */
    var converted = Visited()
    /** The texts and blocks of data converted so far, by the place of their bytes in memory. */
    var convertedBytes: Set<UnsafeRawPointer> = []
    /** More than 0 inside a value that was converted before. */
    var repeating = 0
    /** What the value that is written again can still have, once `budget` is used up. */
    var allowance = 0
    /** How many values, texts and blocks of data were not written in full. */
    var cut = 0
    /** The script whose properties are converted: see `container`. */
    var owner: ScriptTable?

    init(budget: Int = LiteralPath.maxNodes, byteBudget: Int = LiteralPath.maxBytes) {
        self.budget = budget
        self.byteBudget = byteBudget
    }

    /** True when the value being written again can have nothing more. */
    var isExhausted: Bool {
        self.repeating > 0 && self.budget <= 0 && self.allowance <= 0
    }

    /** The mark for what is not written, counted in `cut`. */
    mutating func tooLarge() -> any Expr {
        self.cut += 1
        return Keyword(fallback: "«value too large»")
    }

    /**
     Tells whether a text, or a block of data, can be written in full.

     - `storage`: its bytes, as the file holds them. The place of the
       bytes in memory tells whether they were converted before: the
       values of a file stay where they are while it is decompiled.
     - `printed`: the number of bytes it prints as.
     */
    mutating func takeBytes(_ storage: [UInt8], printed: Int) -> Bool {
        let place = storage.withUnsafeBufferPointer { $0.baseAddress.map { UnsafeRawPointer($0) } }
        let isFirst = place.map { self.convertedBytes.insert($0).inserted } ?? true
        if isFirst, self.repeating == 0 {
            return true
        }
        if printed <= self.byteBudget {
            self.byteBudget -= printed
            return true
        }
        return printed <= Self.smallBytes
    }

    /** A text: in full, or its first characters when it is long and the budget is used up. */
    mutating func text(_ storage: [UInt8], _ value: @autoclosure () -> String) -> any Expr {
        if self.takeBytes(storage, printed: storage.count) {
            return StringLiteral(value: value())
        }
        self.cut += 1
        // The start of the text, on one line.
        let start = String(value().prefix(64).map { $0.isNewline || $0 == "\t" ? " " : $0 })
        return Keyword(fallback: "«long text, \(storage.count) bytes: \"\(start)…\"»")
    }

    /** A block of data: in full, or a mark with its size when it is long and the budget is used up. */
    mutating func data(_ storage: [UInt8], _ value: @autoclosure () -> any Expr) -> any Expr {
        if self.takeBytes(storage, printed: 2 * storage.count) {
            return value()
        }
        self.cut += 1
        return Keyword(fallback: "«long data, \(storage.count) bytes»")
    }

    /** Converts one value: see `Value.literal`. */
    mutating func literal(_ value: Value?) -> any Expr {
        if self.depth >= Self.maxDepth {
            return Keyword(fallback: "«nesting too deep»")
        }
        guard let value else {
            return MissingLiteral()
        }
        // A container that was converted before starts a part that is written again.
        let wasConverted = value.node.map { !self.converted.enter($0) } ?? false
        let startsRepeat = wasConverted && self.repeating == 0
        if startsRepeat {
            self.repeating += 1
            self.allowance = Self.smallNodes
        }
        defer {
            if startsRepeat {
                self.repeating -= 1
            }
        }
        if self.repeating > 0 {
            if self.budget > 0 {
                self.budget -= 1
            } else if self.allowance > 0 {
                self.allowance -= 1
            } else {
                return self.tooLarge()
            }
        }
        guard self.visiting.enter(value) else {
            return Keyword(fallback: "«cyclic reference»")
        }
        self.depth += 1
        defer {
            self.depth -= 1
            self.visiting.leave(value)
        }
        switch value {
        case .null:
            return MissingLiteral()
        case let .boolean(flag):
            return BooleanLiteral(value: flag)
        case let .integer(integer):
            return NumberLiteral(integer: integer)
        case let .real(number):
            return NumberLiteral(real: number, isReal: true)
        case let .special(code):
            switch code {
            case Special.true:
                return BooleanLiteral(value: true)
            case Special.false:
                return BooleanLiteral(value: false)
            default:
                return MissingLiteral()
            }
        case let .constant(code):
            return KeywordCode(packed: code).literal
        case let .bytes(data):
            return self.text(data, String(decoding: data, as: UTF8.self))
        case let .unicodeText(text):
            return self.text(text.text, text.string)
        case let .object(content):
            return self.literal(content)
        case let .rawData(data):
            return self.data(data, data.rawDataLiteral)
        case let .typedData(opaque):
            return self.data(opaque.data, OpaqueLiteral(runtimeType: opaque.type, data: opaque.data))
        case let .descriptor(descriptor):
            if descriptor.type == "ldt ", let date = descriptor.content.longDateLiteral {
                return date
            }
            if descriptor.type == "alis", let name = descriptor.content.aliasTargetName {
                return Application(name: name)
            }
            return self.data(descriptor.content, RawDataLiteral(type: descriptor.type, data: descriptor.content))
        case let .pair(first):
            var elements: [any Expr?] = []
            var seen = Visited()
            var current: Pair? = first
            while let cell = current, !cell.empty, seen.enter(cell) {
                // One mark for all the items that are left, not one for each.
                if self.isExhausted {
                    elements.append(self.tooLarge())
                    break
                }
                elements.append(self.literal(cell.head))
                current = cell.tail.pair
            }
            return List(elements: elements)
        case let .binding(first):
            var fields: [RecordField] = []
            var seen = Visited()
            var current: Binding? = first
            while let cell = current, !cell.empty, seen.enter(cell) {
                if self.isExhausted {
                    fields.append(RecordField(label: self.tooLarge(), value: MissingLiteral()))
                    break
                }
                let label = self.literal(cell.key)
                fields.append(RecordField(label: label, value: self.literal(cell.value)))
                current = cell.next.binding
            }
            return Record(fields: fields)
        case let .vector(vector):
            return self.literal(vector)
        case .eventIdentifier, .statement, .secondActor:
            return Keyword(fallback: "«unsupported \(value.typeName)»")
        }
    }

    /**
     Converts a vector. What it is depends on its runtime class:

     ```
     class 19     the "it" object
     class 177    UTF-16 text, at child 1
     class 4      a list: its items are in the vector at child 2
     class 21…    a stored reference (see `reference`)
     class 20     `a reference to …`, around a stored reference
     other class  the value at child 1
     no class     its only child, or a list of its children
     ```
     */
    private mutating func literal(_ vector: Vector) -> any Expr {
        if vector.hasType, vector.type == 19 {
            return It()
        }
        if vector.hasType, vector.children.count > 1 {
            if vector.type == 177 {
                switch vector.children[1] {
                case let .bytes(data):
                    return self.text(data, String(storedUTF16: data))
                case let .unicodeText(text):
                    return self.text(text.text, text.string)
                default:
                    break
                }
            }
            // A damaged list may have no child 2: it is then read like any
            // other typed vector, below.
            if vector.type == 4, vector.children.count > 2, let nested = vector.children[2].vector {
                let start = nested.hasType ? 1 : 0
                return List(elements: self.literals(nested.children.dropFirst(start)))
            }
            // The empty list has a count of 0 and no vector of items.
            if vector.type == 4, vector.children.count > 2, vector.children[2].isNull, vector.children[1] == .integer(0) {
                return List()
            }
            if let reference = self.reference(vector) {
                return reference
            }
            if vector.type == 20, let inner = vector.children[1].vector, inner.hasType, Self.referenceKinds[inner.type] != nil {
                return Reference(value: self.literal(vector.children[1]))
            }
            return self.literal(vector.children[1])
        }
        if vector.children.count == 1 {
            return self.literal(vector.children[0])
        }
        return List(elements: self.literals(vector.children[...]))
    }

    /** The classes of the stored references, each with its form and the number of its children. */
    static let referenceKinds: [UInt8: (kind: SpecifierKind, count: Int)] = [
        21: (.property, 3), 22: (.every, 3), 23: (.some, 3), 24: (.index, 4), 27: (.range, 5), 32: (.middle, 3),
    ]

    /**
     Converts a stored reference, or returns `nil` for any other vector.
     The container is at child 1, and what is asked of it comes after:

     ```
     class 21   name of x              child 2: the property
     class 22   every item of x        child 2: the class
     class 23   some item of x
     class 24   item 3 of x            child 3: the index, or a name
     class 27   items 1 thru 2 of x    children 3 and 4: the two ends
     class 32   middle item of x
     ```

     The compiler stores one, in place of code, in the value of a
     property (`a reference to item 1 of x`) and for the class of a
     value it knows:

     ```
     class of "x"       class of 5       class of current application
     ```

     A property named with a word of the user is stored as text:
     `alpha of x`.
     */
    private mutating func reference(_ vector: Vector) -> (any Expr)? {
        guard let form = Self.referenceKinds[vector.type], vector.children.count >= form.count else {
            return nil
        }
        let container = self.container(vector.children[1])
        var object = self.literal(vector.children[2])
        if form.kind == .property, let text = object as? StringLiteral, text.value.isName {
            object = Variable(name: text.value)
        }
        let from = form.count > 3 ? self.literal(vector.children[3]) : nil
        let to = form.count > 4 ? self.literal(vector.children[4]) : nil
        return Specifier(kind: form.kind, object: object, container: container, from: from, to: to)
    }

    /**
     Converts the container of a stored reference. A script object
     (class 15) is named, and not written as a value. So is the value
     of a property of the script the reference is in (see `owner`): the
     reference holds that same object, not a copy.

     ```
     a reference to p              the script the reference is in
     a reference to p of inner     another script object, by its name
     a reference to item 1 of p    the value of the property `p`
     ```
     */
    private mutating func container(_ value: Value) -> (any Expr)? {
        if value.isNull {
            return nil
        }
        if let script = value.vector, script.hasType, script.type == 15 {
            if let owner = self.owner, script.children.count > 4, script.children[4].vector === owner.raw {
                return nil
            }
            let name = script.children.count > 1 ? script.children[1].identifier(or: "") : ""
            return name.isEmpty ? nil : Variable(name: name)
        }
        if let node = value.node, let entry = self.owner?.entries.first(where: { $0.value.node === node }), let raw = entry.name?.bytes {
            let name = String(decoding: raw, as: UTF8.self)
            if name.isName {
                return Variable(name: name)
            }
        }
        return self.literal(value)
    }

    /** Converts the items of a list. When nothing more can be written, one mark stands for the items that are left. */
    private mutating func literals(_ values: ArraySlice<Value>) -> [any Expr?] {
        var elements: [any Expr?] = []
        for value in values {
            if self.isExhausted {
                elements.append(self.tooLarge())
                break
            }
            elements.append(self.literal(value))
        }
        return elements
    }
}

extension KeywordCode {
    /** The four-character codes that always print as the same word. */
    static let fixedWords: [Code4: String] = [
        "FTPc": "path", "lnfd": "linefeed", "prun": "running", "rslt": "result",
        "spac": "space", "strq": "quoted form", "pnam": "name", "vers": "version",
    ]

    /**
     The keyword for the code.

     A few codes always print as a fixed word, whatever the terminology
     says, and one code is `current application`.
     */
    var literal: any Expr {
        switch self {
        case .eight("misccura"):
            CurrentApplication()
        case let .four(four):
            Keyword(code: self, fallback: Self.fixedWords[four] ?? "")
        default:
            Keyword(code: self)
        }
    }
}

extension [UInt8] {
    /**
     A raw data block as `«data TYPE…»`, or as a date.

     The first four bytes are the type when they are printable ASCII. If
     not, the type is `****` and all the bytes are content.
     */
    var rawDataLiteral: any Expr {
        var code = Array("****".utf8)
        var content = self
        if self.count >= 4 {
            let head = Array(self[..<4])
            if head.isPrintableASCII {
                code = head
                content = Array(self[4...])
            }
        }
        if code.elementsEqual("ldt ".utf8), let date = content.longDateLiteral {
            return date
        }
        return RawDataLiteral(type: Code4(bytes: code), data: content)
    }

    /**
     A stored long date as an expression: its text when it has one, and
     raw data when it has none (see `DateLiteral.textRange`).

     The compiler keeps the bytes of `«data ldt …»` as a date, in the
     opposite order. So the 8 bytes are written last byte first, and the
     source compiles back to the same date:

     ```
     stored    FF FF FF CE 9E E6 62 4B     (seconds since 1904, big-endian)
     written   «data ldt 4B62E69ECEFFFFFF»
     ```

     The value is `nil` when the data is not exactly 8 bytes.
     */
    var longDateLiteral: any Expr? {
        if self.count != 8 {
            return nil
        }
        return DateLiteral(longDate: self) ?? RawDataLiteral(type: "ldt ", data: self.reversed())
    }

    /**
     The target name of an alias record.

     ```
     offset  6..7   record version, must be 0 2
     offset  50     name length n (1…63)
     offset  51     n bytes: the name
     ```

     A trailing `.app` is removed, so the result can be used as
     `application "Name"`.

     The value is `nil` when the record is too short or looks damaged.
     */
    var aliasTargetName: String? {
        if self.count < 51 || self[6] != 0 || self[7] != 2 {
            return nil
        }
        let count = Int(self[50])
        if count == 0 || count > 63 || 51 + count > self.count {
            return nil
        }
        var name = Array(self[51 ..< 51 + count])
        let suffix = Array(".app".utf8)
        if name.count >= suffix.count, name.suffix(suffix.count).elementsEqual(suffix) {
            name.removeLast(suffix.count)
        }
        if name.isEmpty || name.contains(0) {
            return nil
        }
        return String(decoding: name, as: UTF8.self)
    }
}

extension DateLiteral {
    /**
     Decodes a long date: a signed 64-bit count of seconds since
     1 January 1904, 00:00.

     A date has no text that every Mac reads the same way: the compiler
     reads the text of a date with the formats of the user's settings,
     and `2/3/1970` is 3 February in one country and 2 March in another.
     The tool writes what Apple's tools print with the settings of the
     United States (the locale `en_US_POSIX`):

     ```
     date "Tuesday, February 3, 1970 at 12:00:00 AM"
     ```

     A Mac with other settings does not read the month as the day: it
     refuses this text. The character before `AM` is a narrow no-break
     space (U+202F), as Apple prints it.

     - Returns: `nil` when the data is not exactly 8 bytes, or when the
       date has no text (see `textRange`).
     */
    convenience init?(longDate data: [UInt8]) {
        if data.count != 8 {
            return nil
        }
        let seconds = Int64(bitPattern: data.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        if !Self.textRange.contains(seconds) {
            return nil
        }
        var days = seconds / 86400
        var secondOfDay = seconds % 86400
        if secondOfDay < 0 {
            secondOfDay += 86400
            days -= 1
        }
        // Days from 1904-01-01 to 1970-01-01 = 24107.
        days -= 24107
        let (year, month, day) = days.civilDate
        let hour24 = Int(secondOfDay / 3600)
        let minute = Int(secondOfDay % 3600 / 60)
        let second = Int(secondOfDay % 60)
        let hour = hour24 % 12 == 0 ? 12 : hour24 % 12
        func twoDigits(_ value: Int) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        // 1 January 1970 was a Thursday.
        let weekday = Self.weekdays[Int(((days % 7) + 11) % 7)]
        let monthName = Self.months[Int(month - 1)]
        self.init(
            value: "\(weekday), \(monthName) \(day), \(year) at \(hour):\(twoDigits(minute)):\(twoDigits(second))\u{202F}"
                + (hour24 >= 12 ? "PM" : "AM"),
        )
    }

    /**
     The long dates that have a text the compiler reads back as the same
     date.

     ```
     first   Saturday, January 1, 1 at 12:00:00 AM            -60052924800
     last    Monday, December 19, 5828963 at 2:00:00 PM    183884251730400
     ```

     Before the first, Apple's tools print the year with no era: a day of
     4713 BC is printed with the year `4713`, which the compiler reads as
     a day of 4713 AD. After the last, and for a date some 5.8 million
     years before year 1, they print `date ""`.
     */
    static let textRange: ClosedRange<Int64> = -60_052_924_800 ... 183_884_251_730_400

    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static let months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
}

extension Int64 {
    /**
     The calendar date of a day count (0 = 1 January 1970).

     AppleScript changes calendar where history did: a day before
     15 October 1582 is a date of the Julian calendar, and a later day
     is a date of the Gregorian calendar.

     ```
     day count   -141428            -141427
     date        4 October 1582     15 October 1582
     ```
     */
    var civilDate: (year: Int64, month: Int64, day: Int64) {
        if self < -141_427 {
            return self.julianDate
        }
        // The well-known "civil from days" algorithm.
        let shifted = self + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    /**
     The date of a day count in the Julian calendar, where every fourth
     year is a leap year. The count goes through the Julian day number:
     day 0 (1 January 1970) has the number 2440588.

     The year is the one of astronomers: year 0 is 1 BC, and year -4712
     is 4713 BC.
     */
    private var julianDate: (year: Int64, month: Int64, day: Int64) {
        let shifted = 4 * (self + 2_440_588 + 1401) + 3
        // The division must round down, and Swift rounds toward zero: a
        // day far in the past gave a month below 1 without this.
        var cycle = shifted / 1461
        var rest = shifted % 1461
        if rest < 0 {
            rest += 1461
            cycle -= 1
        }
        let dayOfYear = 5 * (rest / 4) + 2
        let day = (dayOfYear % 153) / 5 + 1
        let month = (dayOfYear / 153 + 2) % 12 + 1
        let year = cycle - 4716 + (14 - month) / 12
        return (year, month, day)
    }
}

extension UnicodeText {
    /** The text: MacRoman for styled text, UTF-16 for any other (see `UnicodeText`). */
    var string: String {
        self.style.isEmpty ? String(storedUTF16: self.text) : String(macRoman: self.text)
    }
}

extension String {
    /**
     Decodes stored UTF-16 big-endian text.

     A payload with an odd number of bytes cannot be UTF-16: it comes from
     a damaged file, and is kept as the bytes it has.

     A payload of printable ASCII bytes is read as UTF-16 like any other:
     `20 26` is "…", and `20 22` is "•", not a space and a quote.
     */
    init(storedUTF16 data: [UInt8]) {
        if data.count % 2 != 0 {
            self.init(decoding: data, as: UTF8.self)
        } else {
            self.init(utf16BigEndian: data)
        }
    }

    /**
     True for text that can be the name of a variable or of a property.
     Any text can, when it is written between bars: `|my name|`. Only an
     empty text and a text with a control character cannot.
     */
    var isName: Bool {
        !self.isEmpty && self.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    /** True for `[A-Za-z_][A-Za-z0-9_]*` (ASCII only). */
    var isPlainIdentifier: Bool {
        if self.isEmpty {
            return false
        }
        for (index, scalar) in self.unicodeScalars.enumerated() {
            let isLetter = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            let isDigit = index > 0 && scalar >= "0" && scalar <= "9"
            if !(isLetter || scalar == "_" || isDigit) {
                return false
            }
        }
        return true
    }
}
