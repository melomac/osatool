/**
 A four-character code, such as `'pnam'` (name) or `'TEXT'` (string).

 Apple events name every class, property and parameter with four bytes in
 the MacRoman encoding. The bytes are kept in one 32-bit number, first
 byte in the highest position.
 */
package struct Code4: Hashable, Sendable {
    package var rawValue: UInt32

    /** Creates the code made of four zero bytes. */
    package init() {
        self.rawValue = 0
    }

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /**
     Creates a code from bytes. Only the first four bytes are used. When
     there are fewer than four, the missing ones are zero.
     */
    package init<C: Collection>(bytes: C) where C.Element == UInt8 {
        var value: UInt32 = 0
        var shift: UInt32 = 24
        for byte in bytes.prefix(4) {
            value |= UInt32(byte) << shift
            shift &-= 8
        }
        self.rawValue = value
    }

    /**
     Parses a code written as text.

     Two forms are accepted:

     - four MacRoman characters, for example `pnam`;
     - `0x` followed by eight hexadecimal digits, for codes that hold
       bytes which cannot be written as text.

     - Throws: when the text does not describe exactly four bytes.
     */
    package init(parsing value: String) throws {
        try self.init(bytes: [UInt8](code: value, width: 4))
    }

    /** The four bytes of the code. */
    package var bytes: [UInt8] {
        [UInt8(truncatingIfNeeded: self.rawValue >> 24), UInt8(truncatingIfNeeded: self.rawValue >> 16),
         UInt8(truncatingIfNeeded: self.rawValue >> 8), UInt8(truncatingIfNeeded: self.rawValue)]
    }

    /** The code as text that `init(parsing:)` reads back. */
    package var text: String {
        self.bytes.codeText
    }
}

/**
 A code can be written as a string literal of four ASCII characters:

 ```swift
 let name: Code4 = "pnam"
 if code == "to  " { … }
 ```
 */
extension Code4: ExpressibleByStringLiteral {
    package init(stringLiteral value: StaticString) {
        assert(value.utf8CodeUnitCount == 4, "a four-character code needs four bytes")
        self.init(bytes: UnsafeBufferPointer(start: value.utf8Start, count: value.utf8CodeUnitCount))
    }
}

/**
 An eight-byte code: two four-character codes side by side.

 It names an Apple event (event class + event ID, for example
 `aevt` + `oapp` for "run"), or an enumeration value (enumeration code +
 member code).
 */
package struct EventCode: Hashable, Sendable {
    package var rawValue: UInt64

    /** Creates the code made of eight zero bytes. */
    package init() {
        self.rawValue = 0
    }

    package init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /**
     Creates a code from bytes. Only the first eight bytes are used. When
     there are fewer than eight, the missing ones are zero.
     */
    package init<C: Collection>(bytes: C) where C.Element == UInt8 {
        var value: UInt64 = 0
        var shift: UInt64 = 56
        for byte in bytes.prefix(8) {
            value |= UInt64(byte) << shift
            shift &-= 8
        }
        self.rawValue = value
    }

    /** Creates a code from its two halves. */
    package init(first: Code4, second: Code4) {
        self.rawValue = UInt64(first.rawValue) << 32 | UInt64(second.rawValue)
    }

    /**
     Parses a code written as text: eight MacRoman characters, or `0x`
     followed by sixteen hexadecimal digits.

     - Throws: when the text does not describe exactly eight bytes.
     */
    package init(parsing value: String) throws {
        try self.init(bytes: [UInt8](code: value, width: 8))
    }

    /** The eight bytes of the code. */
    package var bytes: [UInt8] {
        (0 ..< 8).map { UInt8(truncatingIfNeeded: self.rawValue >> (56 - 8 * UInt64($0))) }
    }

    /** The code as text that `init(parsing:)` reads back. */
    package var text: String {
        self.bytes.codeText
    }

    /** The first half: the event class, or the code of an enumeration. */
    package var first: Code4 {
        Code4(rawValue: UInt32(truncatingIfNeeded: self.rawValue >> 32))
    }

    /** The second half: the event ID, or the member of an enumeration. */
    package var second: Code4 {
        Code4(rawValue: UInt32(truncatingIfNeeded: self.rawValue))
    }
}

/** A code can be written as a string literal of eight ASCII characters: `"aevtoapp"`. */
extension EventCode: ExpressibleByStringLiteral {
    package init(stringLiteral value: StaticString) {
        assert(value.utf8CodeUnitCount == 8, "an eight-character code needs eight bytes")
        self.init(bytes: UnsafeBufferPointer(start: value.utf8Start, count: value.utf8CodeUnitCount))
    }
}

extension [UInt8] {
    /**
     Reads a code written as text: `width` MacRoman characters, or `0x`
     and two hexadecimal digits for each byte.

     - Throws: when the text does not describe exactly `width` bytes.
     */
    init(code value: String, width: Int) throws {
        if value.hasPrefix("0x") {
            guard
                let raw = [UInt8](hex: String(value.dropFirst(2))),
                raw.count == width
            else {
                throw ScriptError("invalid \(width)-byte hexadecimal code \(value.quoted)")
            }
            self = raw
            return
        }
        var raw: [UInt8] = []
        for character in value.unicodeScalars {
            guard let encoded = character.macRomanByte else {
                throw ScriptError("code \(value.quoted) contains a character unavailable in MacRoman")
            }
            raw.append(encoded)
        }
        if raw.count != width {
            throw ScriptError("invalid \(width)-byte code \(value.quoted)")
        }
        self = raw
    }

    /**
     The bytes of a code as text: its MacRoman characters, or `0x` and
     hexadecimal digits when a byte is a control character (or when the
     characters would be read as a hexadecimal code).
     */
    var codeText: String {
        let text = String(macRoman: self)
        if self.contains(where: { $0 < 0x20 || $0 == 0x7f }) || text.hasPrefix("0x") {
            return "0x" + self.hex
        }
        return text
    }
}
