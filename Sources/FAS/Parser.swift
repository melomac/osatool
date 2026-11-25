import Extensions

/**
 The five bytes in front of every stored object.

 ```
 +-------+-----------+-----------+
 | index |    ref    |  inlined  |
 | 1 byte|  2 bytes  |  2 bytes  |
 +-------+-----------+-----------+
 ```

 - `index`: the kind of object (list, integer, record, …).
 - `ref`: the reference number other objects use to point to this one.
 - `inlined`: a size, a count, or the value itself for small objects.
 */
struct Header {
    var index: UInt8 = 0
    var ref: Int16 = 0
    var inlined: UInt16 = 0
    var offset: Int = 0
}

/** The framework stops loading after this many reference mismatches. */
let frameworkRefErrorLimit = 6

/**
 Returns the position of the first byte after the `#!` line that a
 compiled script can start with, and 0 when the data has no such line.

 - Returns: `nil` when the line has no end.
 */
func endOfHashbang(_ data: [UInt8]) -> Int? {
    guard data.starts(with: "#!".utf8) else {
        return 0
    }
    return data.firstIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }
}

/**
 Parses a compiled script.

 The file starts with a short preamble, then one object tree:

 ```
 [#!… line]   optional, skipped
 "Fasd"       magic
 "UAS "       magic
 "1.10"       version
 "1.10"       second version, only when the first one is "1.10" or more
 object       the root object
 ```

 A version is four characters, compared as one signed 32-bit number, as
 the framework does. The first one must be more than "0.97", and the
 second one (the first one again when there is no second) at most "1.10".

 - Throws: `ScriptError` when the data is not a compiled script, is cut short,
   or goes over a limit. In strict mode, also on the first recovered problem.
 */
package func parse(_ input: [UInt8], options: ParseOptions) throws -> Document {
    var options = options
    let defaults = Limits.defaults()
    if options.limits.maxInputBytes <= 0 {
        options.limits.maxInputBytes = defaults.maxInputBytes
    }
    if options.limits.maxObjects <= 0 {
        options.limits.maxObjects = defaults.maxObjects
    }
    if options.limits.maxReferences <= 0 {
        options.limits.maxReferences = defaults.maxReferences
    }
    if options.limits.maxDepth <= 0 {
        options.limits.maxDepth = defaults.maxDepth
    }
    if options.limits.maxBlobBytes <= 0 {
        options.limits.maxBlobBytes = defaults.maxBlobBytes
    }
    if input.count > options.limits.maxInputBytes {
        throw ScriptError("FAS stream exceeds \(options.limits.maxInputBytes)-byte limit")
    }
    let parser = Parser(data: input, options: options)
    let document = try parser.parse()
    document.diagnostics.append(contentsOf: parser.diagnostics)
    return document
}

final class Parser {
    var reader: ByteReader
    var options: ParseOptions
    /** The objects read so far, by their reference number. `nil`: no object has that number yet. */
    var refs: [Value?]
    var objects = 0
    var depth = 0
    var reuse: Header?
    var refErrors = 0
    var diagnostics: [Diagnostic] = []

    /**
     Creates a parser. The table of references starts empty: no number
     is special. The root object is the first one that is stored, and it
     has the reference 0.
     */
    init(data: [UInt8], options: ParseOptions) {
        self.reader = ByteReader(data)
        self.options = options
        self.refs = []
    }

    func parse() throws -> Document {
        guard let start = endOfHashbang(self.reader.data) else {
            throw ScriptError("unterminated hashbang")
        }
        if start > 0 {
            // Offsets are counted from the first byte after the line.
            self.reader = ByteReader(Array(self.reader.data[start...]))
        }
        let magic = try wrapping("read Fasd magic") { try self.readN(4) }
        if !magic.elementsEqual("Fasd".utf8) {
            throw ScriptError("invalid FAS magic \(magic.quoted)")
        }
        let uas = try wrapping("read UAS magic") { try self.readN(4) }
        if !uas.elementsEqual("UAS ".utf8) {
            throw ScriptError("invalid UAS magic \(uas.quoted)")
        }
        let first = try wrapping("read version") { try self.readN(4) }
        var second = first
        if first.versionNumber >= Array("1.10".utf8).versionNumber {
            second = try self.wrapping("read extended version") { try self.readN(4) }
        }
        if first.versionNumber <= Array("0.97".utf8).versionNumber {
            throw ScriptError("FAS version too low: \(first.quoted)")
        }
        if second.versionNumber > Array("1.10".utf8).versionNumber {
            throw ScriptError("FAS version too high: \(second.quoted)")
        }
        let root = try loadObject(0)
        return Document(version: second, root: root)
    }

    func offset() -> Int {
        self.reader.position
    }

    /** Runs `body`; on error, adds the action name and the file offset. */
    func wrapping<T>(_ action: String, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw ScriptError("\(action) at 0x\(self.offset().hex): \(error.message)")
        }
    }

    func readN(_ count: Int) throws -> [UInt8] {
        if count < 0 || count > self.options.limits.maxBlobBytes {
            throw ScriptError("invalid allocation size \(count)")
        }
        return try self.reader.read(count)
    }

    func u8() throws -> UInt8 {
        try self.reader.read(1)[0]
    }

    func u16() throws -> UInt16 {
        let bytes = try reader.read(2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    func s16() throws -> Int16 {
        try Int16(bitPattern: self.u16())
    }

    func u32() throws -> UInt32 {
        let bytes = try reader.read(4)
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    func s32() throws -> Int32 {
        try Int32(bitPattern: self.u32())
    }

    func u64() throws -> UInt64 {
        let bytes = try reader.read(8)
        return bytes.reduce(0) { $0 << 8 | UInt64($1) }
    }

    func readHeader() throws -> Header {
        let start = self.offset()
        let index = try u8()
        let ref = try s16()
        let size = try u16()
        return Header(index: index, ref: ref, inlined: size, offset: start)
    }

    /**
     Loads the next object and checks that it has the expected reference.

     When the reference is not the expected one, the framework does not
     fail at once. It keeps the header for the next read and uses `.null` in
     place of the missing object. The parser does the same, records a
     diagnostic, and gives up at the sixth mismatch (or the first one in
     strict mode).
     */
    func loadObject(_ expected: Int16) throws -> Value {
        let header: Header
        if let pending = reuse {
            header = pending
            self.reuse = nil
        } else {
            header = try self.wrapping("read object header") { try self.readHeader() }
        }
        if header.ref != expected {
            let message = "RefID mismatch: expected \(expected), found \(header.ref)"
            self.diagnostics.append(Diagnostic(stage: .parse, offset: header.offset, message: message))
            self.reuse = header
            self.refErrors += 1
            if self.options.strict || self.refErrors >= frameworkRefErrorLimit {
                throw ScriptError(message)
            }
            return .null
        }
        return try self.loadNested(header)
    }

    /**
     Reads the body of an object that is inside another one, which is
     one more level of nesting. Every body that a body reads goes through
     here, so that a file cannot make the parser call itself without end:

     ```
     list ── tail ──▶ record ── next ──▶ list ── tail ──▶ record ── …
     ```

     - Throws: when the nesting is deeper than `maxDepth`.
     */
    func loadNested(_ header: Header) throws -> Value {
        if self.depth >= self.options.limits.maxDepth {
            throw ScriptError("object nesting exceeds \(self.options.limits.maxDepth)")
        }
        self.depth += 1
        defer { depth -= 1 }
        return try self.loadBody(header.ref, header.index, header.inlined)
    }

    /**
     Counts one more object of the file.

     - Throws: when the file has more than `maxObjects` objects.
     */
    func countObject() throws {
        self.objects += 1
        if self.objects > self.options.limits.maxObjects {
            throw ScriptError("object count exceeds \(self.options.limits.maxObjects)")
        }
    }

    /**
     Returns the object stored under `ref`, or `nil` when not loaded yet.

     Reference 0 is the root object, as any other reference is its
     object. A script object inside the script points to the root this
     way, as the script around it:

     ```
     root script (ref 0)  ──▶  …  ──▶  script object "helper"
            ▲                                   │
            └────────── ref 0 ──────────────────┘
     ```

     An object that is nothing is not stored as a reference to 0: it is
     an object of kind 1, with a reference of its own.
     */
    func lookup(_ ref: Int16) -> Value? {
        if ref < 0 || Int(ref) >= self.refs.count {
            return nil
        }
        return self.refs[Int(ref)]
    }

    func register(_ ref: Int16, _ value: Value) throws {
        if ref < 0 {
            return
        }
        if Int(ref) >= self.options.limits.maxReferences {
            throw ScriptError("reference \(ref) exceeds limit")
        }
        if Int(ref) >= self.refs.count {
            self.refs.append(contentsOf: Array(repeating: nil, count: Int(ref) - self.refs.count + 1))
        }
        self.refs[Int(ref)] = value
    }

    /** Stores `value` under `ref` and returns it. */
    func registered(_ ref: Int16, _ value: Value) throws -> Value {
        try self.register(ref, value)
        return value
    }

    /** Returns a known object, or loads it from the stream when it is new. */
    func find(_ ref: Int16) throws -> Value {
        if let value = lookup(ref) {
            return value
        }
        return try self.loadObject(ref)
    }

    /**
     Reads the body of an object. `index` selects the kind:

     ```
      1 nil              9 boolean          15 data block
      2 list            10 code identifier  16 pointer block
      3 short integer   11 user identifier  17 byte string
      4 value block     12 Unicode text     18 long data block
      6 record          13 statement        19 long byte string
      7 long integer    14 value block
      8 real
     ```

     The body also stores the object under its reference, as the
     framework does, so that a later reference finds it:

     ```
     stored       list cell, record field, value block, real, Unicode text,
                  statement, data block, pointer block, byte string
     not stored   nil, short and long integer, boolean, code and user
                  identifier, the empty list, the empty record
     ```

     A reference to an object that is not stored is not found: the next
     object of the stream is loaded for it. A container is stored before
     its children are loaded, because a child can point back to it.
     */
    func loadBody(_ ref: Int16, _ index: UInt8, _ size: UInt16) throws -> Value {
        try self.countObject()
        switch index {
        case 1:
            if size != 0 {
                throw ScriptError("nil object size must be zero")
            }
            return .null
        case 2:
            return try self.loadList(ref, size)
        case 3:
            return .integer(Int64(Int16(bitPattern: size)))
        case 4, 14:
            return try self.loadValueBlock(ref, size)
        case 6:
            return try self.loadRecord(ref, size)
        case 7:
            if size != 4 {
                throw ScriptError("long integer size must be 4")
            }
            return try .integer(Int64(self.s32()))
        case 8:
            if size != 8 {
                throw ScriptError("float size must be 8")
            }
            return try self.registered(ref, .real(Double(bitPattern: self.u64())))
        case 9:
            // The framework reads the low byte only: 0x0100 is false.
            return .boolean(size & 0xff != 0)
        case 10:
            return try self.loadCodeIdentifier(size)
        case 11:
            return try self.loadUserIdentifier(size)
        case 12:
            return try self.registered(ref, self.loadUnicodeText(size))
        case 13:
            return try self.loadStatement(ref, size)
        case 15:
            return try self.loadDataBlock(ref, size)
        case 16:
            return try self.loadPointerBlock(ref, size)
        case 17:
            return try self.registered(ref, .bytes(self.readN(Int(size))))
        case 18:
            return try self.registered(ref, self.loadLongDataBlock())
        case 19:
            let count = try u32()
            return try self.registered(ref, .bytes(self.readN(Int(count))))
        default:
            throw ScriptError("unknown FAS object type \(index)")
        }
    }

    /**
     Reads `count - offset` reference numbers, then loads each object.

     The first `offset` slots hold no reference and are filled with `.null`.
     */
    func loadRefs(_ count: Int, _ offset: Int) throws -> [Value] {
        if count < 0 || count > self.options.limits.maxReferences {
            throw ScriptError("invalid reference vector length \(count)")
        }
        var references = [Int16](repeating: 0, count: count)
        var index = offset
        while index < count {
            references[index] = try self.s16()
            index += 1
        }
        var out = [Value](repeating: .null, count: count)
        index = offset
        while index < count {
            out[index] = try self.find(references[index])
            index += 1
        }
        return out
    }

    /**
     Reads a block of references.

     The block is registered before its children are loaded, because a
     child can point back to it. A script object stores a reference to
     the script around it (its parent), and that script is still being
     loaded at that point:

     ```
     script table (ref 2)  ──▶  … ──▶  script object "main"
            ▲                                  │
            └────────── parent ────────────────┘
     ```
     */
    func loadPointerBlock(_ ref: Int16, _ size: UInt16) throws -> Value {
        let vector = Vector()
        try register(ref, .vector(vector))
        vector.children = try self.loadRefs(Int(size), 0)
        return .vector(vector)
    }

    func loadValueBlock(_ ref: Int16, _ size: UInt16) throws -> Value {
        let tag = try u8()
        if size == 0, tag == 15 {
            try self.register(ref, .secondActor)
            return .secondActor
        }
        // Registered before its children: see `loadPointerBlock`.
        let vector = Vector(type: tag, hasType: true)
        try register(ref, .vector(vector))
        if size == 0xffff {
            // The framework adds 1 to the size in 16 bits: the count is 0,
            // and it reads no reference. Slot 0 is kept, as for any block.
            let message = "value block of size 65535 is read as empty"
            self.diagnostics.append(Diagnostic(stage: .parse, offset: self.offset(), message: message))
            if self.options.strict {
                throw ScriptError(message)
            }
            vector.children = [.null]
            return .vector(vector)
        }
        vector.children = try self.loadRefs(Int(size) + 1, 1)
        return .vector(vector)
    }

    /**
     Reads a linked list. Each cell stores two references:

     ```
     cell: [head ref][tail ref]  →  cell: [head ref][tail ref]  →  …
     ```

     The tail is followed in a loop, not by recursion, so a long list does
     not use the nesting budget. Each cell is one object of the file. A
     tail that is not a list is an object inside the last cell.

     Each cell is stored under its reference before its item is loaded:
     an item can point back to the list it is in.
     */
    func loadList(_ ref: Int16, _ size: UInt16) throws -> Value {
        if size == 0 {
            return .pair(Pair(empty: true))
        }
        if size != 2 {
            throw ScriptError("unknown FAS list type \(size)")
        }
        let head = Pair(tail: .pair(Pair(empty: true)))
        var current = head
        try self.register(ref, .pair(head))
        while true {
            let headRef = try s16()
            let tailRef = try s16()
            current.head = try self.find(headRef)
            if let tail = lookup(tailRef) {
                current.tail = tail
                return .pair(head)
            }
            let header = try readHeader()
            if header.index != 2 {
                current.tail = try self.loadNested(header)
                return .pair(head)
            }
            if header.inlined != 2 {
                if header.inlined != 0 {
                    throw ScriptError("list tail size must be zero")
                }
                current.tail = .pair(Pair(empty: true))
                return .pair(head)
            }
            try self.countObject()
            let next = Pair(tail: .pair(Pair(empty: true)))
            current.tail = .pair(next)
            current = next
            try self.register(header.ref, .pair(current))
        }
    }

    /**
     Reads a record: a chain of bindings. Each binding stores three
     references: key, value, and the next binding.

     Each binding is stored under its reference before its key and its
     value are loaded. As in a list, each binding is one object of the
     file, and a next part that is not a record is an object inside the
     last binding.
     */
    func loadRecord(_ ref: Int16, _ size: UInt16) throws -> Value {
        var size = size
        if size == 0 {
            return .binding(Binding(empty: true))
        }
        if size != 3 {
            throw ScriptError("unknown FAS record type \(size)")
        }
        let head = Binding()
        var current = head
        try register(ref, .binding(head))
        while size == 3 {
            let keyRef = try s16()
            let valueRef = try s16()
            let nextRef = try s16()
            current.key = try self.find(keyRef)
            current.value = try self.find(valueRef)
            if let next = lookup(nextRef) {
                current.next = next
                break
            }
            let header = try readHeader()
            if header.index != 6 {
                current.next = try self.loadNested(header)
                break
            }
            size = header.inlined
            if size != 3 {
                if size != 0 {
                    throw ScriptError("record tail size must be zero")
                }
                break
            }
            try self.countObject()
            let next = Binding()
            try self.register(header.ref, .binding(next))
            current.next = .binding(next)
            current = next
        }
        return .binding(head)
    }

    func loadCodeIdentifier(_ size: UInt16) throws -> Value {
        let tag = try u8()
        switch tag {
        case 11:
            if size != 8 {
                throw ScriptError("code identifier size \(size), want 8")
            }
            return try .object(.constant(self.u64()))
        case 10, 47:
            if size != 4 {
                throw ScriptError("code identifier size \(size), want 4")
            }
            return try .object(.constant(UInt64(self.u32())))
        case 46:
            if size != 24 {
                throw ScriptError("event identifier size \(size), want 24")
            }
            var words: [Code4] = []
            for _ in 0 ..< 6 {
                try words.append(Code4(bytes: self.readN(4)))
            }
            // The file stores the six fields in the order a b c d f e.
            words.swapAt(4, 5)
            return .object(.eventIdentifier(EventIdentifier(fields: words)))
        default:
            throw ScriptError("unknown code identifier tag \(tag)")
        }
    }

    /**
     Reads a user identifier (a variable or handler name).

     ```
     [48][key length][key bytes][value length][value bytes]
     ```

     The value is the name as the user typed it. When it is empty, the key
     is the name.
     */
    func loadUserIdentifier(_ size: UInt16) throws -> Value {
        let tag = try u8()
        if tag != 48 {
            throw ScriptError("invalid user identifier marker")
        }
        let keyLength = try u16()
        if keyLength >= 0x100 {
            throw ScriptError("oversized user identifier key")
        }
        let key = try readN(Int(keyLength))
        let valueLength = try u16()
        if valueLength >= 0x100 {
            throw ScriptError("oversized user identifier value")
        }
        var value = try readN(Int(valueLength))
        if valueLength == 0 {
            value = key
        }
        let payload = UInt32(keyLength) + UInt32(valueLength) + 4
        if payload != UInt32(size) {
            throw ScriptError("user identifier payload size \(payload), want \(size)")
        }
        return .bytes(value)
    }

    func loadUnicodeText(_ size: UInt16) throws -> Value {
        let textLength = try u16()
        let text = try readN(Int(textLength))
        let styleLength = try u16()
        let style = try readN(Int(styleLength))
        let payload = UInt32(textLength) + UInt32(styleLength) + 4
        if payload != UInt32(size) {
            throw ScriptError("Unicode text payload size \(payload), want \(size)")
        }
        if style.count < 2 {
            throw ScriptError("Unicode text style table is truncated")
        }
        // The table is a count, then 20 bytes for each style. The count is
        // big-endian. The framework also takes it with its two bytes the
        // other way round, when only that fits the size.
        let styleCount = Int(UInt16(style[0]) << 8 | UInt16(style[1]))
        let swappedCount = Int(UInt16(style[1]) << 8 | UInt16(style[0]))
        let want = 2 + 20 * styleCount
        if style.count != want, style.count != 2 + 20 * swappedCount {
            throw ScriptError("Unicode text style table size \(style.count), want \(want)")
        }
        return .object(.unicodeText(UnicodeText(text: text, style: style)))
    }

    /**
     Reads a statement of the stored source. It is stored under its
     reference before its children are loaded: see `loadPointerBlock`.
     */
    func loadStatement(_ ref: Int16, _ size: UInt16) throws -> Value {
        let tag = try u8()
        let typeInfo = try u16()
        let start = try u16()
        let end = try u16()
        let statement = Statement(tag: tag, typeInfo: typeInfo, start: start, end: end)
        try self.register(ref, .statement(statement))
        statement.children = try self.loadRefs(Int(size) + 3, 3)
        return .statement(statement)
    }

    /**
     Reads a data block. Tag 8 is an Apple event descriptor:

     ```
     [82 bytes][4 bytes][4 bytes][type: 4 bytes][content: size - 94 bytes]
     ```

     Any other tag is a runtime value, decoded by `Value.init(dataBlock:_:)`.
     */
    func loadDataBlock(_ ref: Int16, _ size: UInt16) throws -> Value {
        let tag = try u8()
        let value: Value
        if tag == 8 {
            if size < 94 {
                throw ScriptError("descriptor size \(size) below header size")
            }
            _ = try self.readN(82)
            _ = try self.u32()
            _ = try self.readN(4)
            let type = try readN(4)
            let content = try readN(Int(size) - 94)
            value = .descriptor(Descriptor(type: Code4(bytes: type), content: content))
        } else {
            let bytes = try readN(Int(size))
            value = Value(dataBlock: tag, bytes)
        }
        try self.register(ref, value)
        return value
    }

    func loadLongDataBlock() throws -> Value {
        let tag = try u8()
        let count = try u32()
        let bytes = try readN(Int(count))
        return Value(dataBlock: tag, bytes)
    }
}

extension [UInt8] {
    /**
     The four characters of a version as one signed number, big-endian:
     the way the framework compares two versions. A first byte of 0x80 or
     more makes a negative number, which is lower than any real version.
     */
    var versionNumber: Int32 {
        Int32(bitPattern: self.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
}

extension Value {
    /** Builds the value for a data block from its class tag and its bytes. */
    init(dataBlock tag: UInt8, _ bytes: [UInt8]) {
        func bigEndian() -> UInt64 {
            var number: UInt64 = 0
            for byte in bytes {
                number = number << 8 | UInt64(byte)
            }
            return number
        }
        self = switch tag {
        case 2:
            .special(bigEndian())
        case 6:
            .integer(Int64(bitPattern: bigEndian()))
        case 11:
            .constant(bigEndian())
        case 13:
            .rawData(bytes)
        case 0:
            .bytes(bytes)
        case 0xb1:
            .unicodeText(UnicodeText(text: bytes))
        default:
            .typedData(TypedData(type: tag, data: bytes))
        }
    }
}
