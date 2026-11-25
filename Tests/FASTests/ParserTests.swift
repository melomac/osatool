import Extensions
@testable import FAS
import Testing
import TestSupport

// MARK: Helpers shared by the tests of this target

/**
 Checks that `body` throws, and that the error text contains `want`.
 */
func expectError<T>(
    containing want: String, sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> T,
) {
    do {
        _ = try body()
        Issue.record("no error, want an error with \(want.quoted)", sourceLocation: sourceLocation)
    } catch {
        let text = error.message
        #expect(text.contains(want), "error = \(text), want \(want.quoted)", sourceLocation: sourceLocation)
    }
}

/** The options given to a hand-made parser: the default limits. */
let defaultOptions = ParseOptions(limits: .defaults())

/** A big-endian 16-bit number as two bytes. */
func bigEndian16(_ value: Int) -> [UInt8] {
    [UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
}

/** A big-endian 32-bit number as four bytes. */
func bigEndian32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
}

/** A big-endian 64-bit number as eight bytes. */
func bigEndian64(_ value: UInt64) -> [UInt8] {
    (0 ..< 8).map { UInt8(value >> (56 - 8 * UInt64($0)) & 0xff) }
}

// MARK: - Tests

@Test func `integer header is signed`() throws {
    let parser = Parser(data: [3, 0xff, 0xff, 0xff, 0xfe], options: defaultOptions)
    let header = try parser.readHeader()
    #expect(header.index == 3)
    #expect(header.ref == -1)
    #expect(header.inlined == 0xfffe)
    let value = try parser.loadBody(header.ref, header.index, header.inlined)
    #expect(value == .integer(-2))
}

@Test func `preamble versions`() throws {
    let object: [UInt8] = [3, 0, 0, 0, 1]
    let prefixes: [[UInt8]] = [[], Array("#!/usr/bin/osascript\n".utf8)]
    for prefix in prefixes {
        let data = prefix + Array("FasdUAS ".utf8) + Array("1.10".utf8) + Array("1.10".utf8) + object
        let document = try parse(data, options: ParseOptions())
        #expect(document.version == Array("1.10".utf8))
        #expect(document.root == .integer(1))
    }
}

@Test(arguments: [
    ("too-low", "FasdUAS 0.97", "version too low"),
    ("too-high", "FasdUAS 1.111.11", "version too high"),
])
func `preamble rejects unsupported versions`(name _: String, data: String, want: String) {
    expectError(containing: want) {
        try parse(Array(data.utf8), options: ParseOptions())
    }
}

/**
 The framework compares a version as one signed 32-bit number. The low
 limit is checked on the first version, and the high limit on the second
 one. So a second version below "0.97" is accepted, and a first version
 that starts with a byte of 0x80 or more is a negative number: too low.
 */
@Test func `versions are compared as the framework compares them`() throws {
    let object: [UInt8] = [3, 0, 0, 0, 1]
    let low = try parse(Array("FasdUAS 1.100.50".utf8) + object, options: ParseOptions())
    #expect(low.version == Array("0.50".utf8))
    #expect(low.root == .integer(1))

    // No second version is read after a first one below "1.10".
    let old = try parse(Array("FasdUAS 1.00".utf8) + object, options: ParseOptions())
    #expect(old.version == Array("1.00".utf8))

    expectError(containing: "version too low") {
        try parse(Array("FasdUAS ".utf8) + [0xff, 0x2e, 0x31, 0x30] + Array("1.10".utf8) + object, options: ParseOptions())
    }
    expectError(containing: "version too high") {
        try parse(Array("FasdUAS 9.101.11".utf8) + object, options: ParseOptions())
    }
    #expect(Array("1.10".utf8).versionNumber == 0x312e_3130)
    #expect([UInt8]([0xff, 0x2e, 0x31, 0x30]).versionNumber < 0)
}

@Test(arguments: ["demo.scpt", "seccon.scpt"])
func `bundled scripts parse`(name: String) throws {
    let document = try parse(TestData.bytes(name), options: ParseOptions())
    let root = try #require(document.root.vector, "root type \(document.root.typeName), want vector")
    // The script table is the last child, so there must be one child or more.
    #expect(!root.children.isEmpty)
}

@Test func `strict reference mismatch`() {
    let data = Array("FasdUAS 1.10".utf8) + Array("1.10".utf8) + [3, 0, 1, 0, 1]
    #expect(throws: (any Error).self, "expected mismatch error") {
        try parse(data, options: ParseOptions(strict: true))
    }
}

@Test func `permissive reference mismatch reuses header`() throws {
    let parser = Parser(data: [3, 0xff, 0xe5, 0x00, 0x07], options: defaultOptions)

    var value = try parser.loadObject(0)
    #expect(value == .null)
    #expect(parser.reuse != nil)
    #expect(parser.diagnostics.count == 1)
    #expect(parser.diagnostics.first?.message.contains("expected 0, found -27") == true)
    // The position is the one of the object header in the file.
    #expect(parser.diagnostics.first?.stage == .parse)
    #expect(parser.diagnostics.first?.offset == 0 && parser.diagnostics.first?.function == nil)

    value = try parser.loadObject(-27)
    #expect(value == .integer(7))
    #expect(parser.reuse == nil)
}

@Test func `permissive reference mismatch recovery stops at framework limit`() throws {
    let parser = Parser(data: [3, 0, 47, 0, 7], options: defaultOptions)

    for expected: Int16 in 32 ..< 37 {
        let value = try parser.loadObject(expected)
        #expect(value == .null, "missing reference \(expected) is not nil")
    }
    expectError(containing: "expected 37, found 47") {
        try parser.loadObject(37)
    }
}

/** An object that is kept under its reference cannot have a reference above the limit. */
@Test func `a reference above the limit is refused`() throws {
    var limits = Limits.defaults()
    limits.maxReferences = 3
    // A real number is kept under its reference: kind 8, the reference, the size 8, eight bytes.
    func real(_ reference: Int) -> [UInt8] {
        [8] + bigEndian16(reference) + [0, 8] + [UInt8](repeating: 0, count: 8)
    }
    let parser = Parser(data: real(2) + real(3), options: ParseOptions(limits: limits))
    #expect(try parser.loadObject(2) == .real(0))
    expectError(containing: "reference 3 exceeds limit") {
        try parser.loadObject(3)
    }
    // A block of references cannot be longer than the limit either.
    let block = Parser(data: [16, 0, 0, 0, 4], options: ParseOptions(limits: limits))
    expectError(containing: "invalid reference vector length 4") {
        try block.loadObject(0)
    }
}

/**
 The framework keeps only some kinds of object in its table of
 references. A short integer is not kept: a second reference to its
 number does not find it, and the next object of the stream is loaded.
 `osadecompile` refuses a file of ours where two items of a list share
 the reference of one short integer.
 */
@Test func `a small object is not kept under its reference`() throws {
    let cases: [(name: String, data: [UInt8], value: Value)] = [
        ("nil", [1, 0, 47, 0, 0], .null),
        ("short integer", [3, 0, 47, 0, 10], .integer(10)),
        ("long integer", [7, 0, 47, 0, 4, 0, 0, 0, 10], .integer(10)),
        ("boolean", [9, 0, 47, 0, 1], .boolean(true)),
        ("code identifier", [10, 0, 47, 0, 4, 10] + Array("pnam".utf8), .object(.constant(0x706e_616d))),
        ("user identifier", [11, 0, 47, 0, 5, 48, 0, 1, 0x78, 0, 0], .bytes([0x78])),
        ("empty list", [2, 0, 47, 0, 0], .pair(Pair(empty: true))),
        ("empty record", [6, 0, 47, 0, 0], .binding(Binding(empty: true))),
    ]
    for (name, data, value) in cases {
        let parser = Parser(data: data, options: defaultOptions)
        let loaded = try parser.loadObject(47)
        // Two empty containers are two instances: only the kind is compared.
        #expect(loaded.typeName == value.typeName, "\(name)")
        if loaded.node == nil {
            #expect(loaded == value, "\(name)")
        }
        #expect(parser.lookup(47) == nil, "\(name) is kept")
    }
}

@Test func `a larger object is kept under its reference`() throws {
    let cases: [(name: String, data: [UInt8])] = [
        ("real", [8, 0, 47, 0, 8] + bigEndian64(3.25.bitPattern)),
        ("Unicode text", [12, 0, 47, 0, 8, 0, 2, 0, 0x41, 0, 2, 0, 0]),
        ("byte string", [17, 0, 47, 0, 2, 0x41, 0x42]),
        ("long byte string", [19, 0, 47, 0, 0, 0, 0, 0, 2, 0x41, 0x42]),
        ("data block", [15, 0, 47, 0, 2, 13, 0x41, 0x42]),
        ("long data block", [18, 0, 47, 0, 0, 13, 0, 0, 0, 2, 0x41, 0x42]),
        ("pointer block", [16, 0, 47, 0, 0]),
        ("value block", [14, 0, 47, 0, 0, 0]),
    ]
    for (name, data) in cases {
        let parser = Parser(data: data, options: defaultOptions)
        let loaded = try parser.loadObject(47)
        #expect(parser.lookup(47) == loaded, "\(name) is not kept")
        #expect(parser.reader.remaining == 0, "\(name)")
    }
}

/** The framework looks at the low byte of the size only. */
@Test func `a boolean is its low byte`() throws {
    let parser = Parser(data: [], options: defaultOptions)
    #expect(try parser.loadBody(-1, 9, 0x0000) == .boolean(false))
    #expect(try parser.loadBody(-1, 9, 0x0001) == .boolean(true))
    #expect(try parser.loadBody(-1, 9, 0x0100) == .boolean(false))
    #expect(try parser.loadBody(-1, 9, 0x0201) == .boolean(true))
}

/**
 A container is kept under its reference before its children are loaded,
 so a child can be the container itself.
 */
@Test func `a list, a record and a statement can hold themselves`() throws {
    // A list (reference 1) whose first item is the list.
    //   0001 fffe           item: reference 1, rest: reference -2
    //   02 fffe 0000        the rest: the empty list
    var parser = Parser(data: [0, 1, 0xff, 0xfe, 2, 0xff, 0xfe, 0, 0], options: defaultOptions)
    let list = try #require(parser.loadBody(1, 2, 2).pair)
    #expect(list.head == .pair(list))
    #expect(parser.lookup(1) == .pair(list))

    // A statement (reference 1) with one child: itself.
    //   6d 0000 0000 0001   tag, type, start, end
    //   0001                child: reference 1
    parser = Parser(data: [0x6d, 0, 0, 0, 0, 0, 1, 0, 1], options: defaultOptions)
    let statement = try #require(parser.loadBody(1, 13, 1).node as? Statement)
    #expect(statement.children.count == 4)
    #expect(statement.children[3] == .statement(statement))

    // A record (reference 1) of two fields. The second field has the
    // reference 2, and its value is the second field itself.
    //   ffff fffe 0002      key -1, value -2, next 2
    //   03 ffff 0001        key: 1
    //   03 fffe 0002        value: 2
    //   06 0002 0003        next field, reference 2
    //   fffd 0002 fffc      key -3, value: reference 2, next -4
    //   03 fffd 0003        key: 3
    //   06 fffc 0000        the end
    parser = Parser(
        data: [
            0xff, 0xff, 0xff, 0xfe, 0, 2,
            3, 0xff, 0xff, 0, 1,
            3, 0xff, 0xfe, 0, 2,
            6, 0, 2, 0, 3,
            0xff, 0xfd, 0, 2, 0xff, 0xfc,
            3, 0xff, 0xfd, 0, 3,
            6, 0xff, 0xfc, 0, 0,
        ],
        options: defaultOptions,
    )
    let record = try #require(parser.loadBody(1, 6, 3).binding)
    let second = try #require(record.next.binding)
    #expect(record.key == .integer(1) && record.value == .integer(2))
    #expect(second.key == .integer(3))
    #expect(second.value == .binding(second))
    #expect(parser.lookup(2) == .binding(second))
    #expect(parser.reader.remaining == 0)
}

/** After a field, the framework takes a field or the end, nothing else. */
@Test func `a record tail of another size is an error`() {
    //   ffff fffe fffd      key -1, value -2, next -3
    //   03 ffff 0001  03 fffe 0002
    //   06 fffd 0005        a record of size 5
    let parser = Parser(
        data: [0xff, 0xff, 0xff, 0xfe, 0xff, 0xfd, 3, 0xff, 0xff, 0, 1, 3, 0xff, 0xfe, 0, 2, 6, 0xff, 0xfd, 0, 5],
        options: defaultOptions,
    )
    expectError(containing: "record tail size must be zero") {
        try parser.loadBody(1, 6, 3)
    }
}

/**
 The framework adds 1 to the size of a value block in 16 bits. With the
 size 65535 the count is 0, and no reference is read.
 */
@Test func `a value block of size 65535 is read as empty`() throws {
    let parser = Parser(data: [0, 0xaa, 0xbb], options: defaultOptions)
    let block = try #require(parser.loadBody(1, 14, 0xffff).vector)
    #expect(block.children == [.null])
    #expect(parser.reader.remaining == 2, "only the class byte is read")
    #expect(parser.diagnostics.count == 1)

    let strict = Parser(data: [0, 0xaa, 0xbb], options: ParseOptions(strict: true, limits: .defaults()))
    expectError(containing: "65535") {
        try strict.loadBody(1, 14, 0xffff)
    }
}

/**
 The count of a style table is big-endian. The framework also takes it
 with its two bytes the other way round, when only that fits the size.
 */
@Test func `a style table with a swapped count is accepted`() throws {
    let text: [UInt8] = [0, 0x41]
    for count: [UInt8] in [[0, 1], [1, 0]] {
        let style = count + [UInt8](repeating: 0, count: 20)
        let data = bigEndian16(text.count) + text + bigEndian16(style.count) + style
        let parser = Parser(data: data, options: defaultOptions)
        let value = try parser.loadBody(-1, 12, UInt16(data.count))
        #expect(value.typeName == "object")
    }
    // A count that fits in neither order.
    let style: [UInt8] = [0, 3] + [UInt8](repeating: 0, count: 20)
    let data = bigEndian16(text.count) + text + bigEndian16(style.count) + style
    let parser = Parser(data: data, options: defaultOptions)
    expectError(containing: "style table size") {
        try parser.loadBody(-1, 12, UInt16(data.count))
    }
}

@Test func `primitive object readers`() throws {
    let parser = Parser(data: [], options: defaultOptions)
    #expect(try parser.loadBody(-1, 3, 0xffff) == .integer(-1), "inline integer")
    #expect(try parser.loadBody(-1, 9, 1) == .boolean(true), "boolean")

    let negative: Int32 = -42
    parser.reader = ByteReader(bigEndian32(UInt32(bitPattern: negative)))
    #expect(try parser.loadBody(-1, 7, 4) == .integer(-42), "long")

    parser.reader = ByteReader(bigEndian64(3.25.bitPattern))
    #expect(try parser.loadBody(-1, 8, 8) == .real(3.25), "float")
}

/** The file stores the six event fields in the order a b c d f e. */
@Test func `code identifier event order`() throws {
    let data: [UInt8] = [46] + Array("aaaabbbbccccddddeeeeffff".utf8)
    let parser = Parser(data: data, options: defaultOptions)
    let value = try parser.loadBody(-1, 10, 24)
    guard case let .object(.eventIdentifier(event)) = value else {
        Issue.record("the value is \(value.typeName), want an event identifier in an object")
        return
    }
    #expect(event.fields == ["aaaa", "bbbb", "cccc", "dddd", "ffff", "eeee"])
    #expect(event.code == "aaaabbbb")
}

@Test func `reference registration growth`() throws {
    let parser = Parser(data: [], options: defaultOptions)
    // A reference table with one entry that was never seen.
    parser.refs = [nil]
    let value = Value.integer(42)
    try parser.register(40, value)
    let got = try #require(parser.lookup(40), "reference 40 is not resolved")
    #expect(got == value)
    #expect(parser.lookup(-1) == nil, "negative reference resolved")
}

// MARK: - Limits

/** The first bytes of a compiled script: the magic and the two versions. */
private let preamble = Array("FasdUAS 1.101.10".utf8)

/**
 A list of `cells` cells. Each item is the reference 0, the list itself,
 so that no other object is in the file.
 */
private func listStream(cells: Int) -> [UInt8] {
    let cell: [UInt8] = [0, 0, 0xff, 0xff, 2, 0xff, 0xff, 0, 2]
    let last: [UInt8] = [0, 0, 0xff, 0xff, 2, 0xff, 0xff, 0, 0]
    return [2, 0, 0, 0, 2] + [[UInt8]](repeating: cell, count: cells - 1).joined() + last
}

/** A record of `fields` bindings, with the record itself as each key and each value. */
private func recordStream(fields: Int) -> [UInt8] {
    let field: [UInt8] = [0, 0, 0, 0, 0xff, 0xff, 6, 0xff, 0xff, 0, 3]
    let last: [UInt8] = [0, 0, 0, 0, 0xff, 0xff, 6, 0xff, 0xff, 0, 0]
    return [6, 0, 0, 0, 3] + [[UInt8]](repeating: field, count: fields - 1).joined() + last
}

/**
 A list whose tail is a record, whose next part is a list, and so on:

 ```
 list ── tail ──▶ record ── next ──▶ list ── tail ──▶ record ── …
 ```

 No cell is nested in another one, but each one is read by a call from
 the one before. Without a count of these calls, a file of one megabyte
 filled the stack and the program crashed.
 */
@Test func `a chain of tails counts as nesting`() {
    let round: [UInt8] = [0, 0, 0xff, 0xff, 6, 0xff, 0xff, 0, 3, 0, 0, 0, 0, 0xff, 0xff, 2, 0xff, 0xff, 0, 2]
    func chain(_ rounds: Int) -> [UInt8] {
        preamble + [2, 0, 0, 0, 2] + [[UInt8]](repeating: round, count: rounds).joined()
    }
    var limits = Limits.defaults()
    limits.maxDepth = 16
    expectError(containing: "object nesting exceeds 16") {
        try parse(chain(100), options: ParseOptions(limits: limits))
    }
    // Under the limit the chain is read to its end, which is the end of the file.
    expectError(containing: "end of data") {
        try parse(chain(4), options: ParseOptions(limits: limits))
    }
    // The size that crashed, with a limit that a small stack can hold.
    limits.maxDepth = 64
    expectError(containing: "object nesting exceeds 64") {
        try parse(chain(50000), options: ParseOptions(limits: limits))
    }
}

/** Objects nested in the plain way are counted too: a block inside a block. */
@Test func `objects cannot be nested deeper than the limit`() throws {
    // A block of one reference, which is the next object: kind 16, reference -1, size 1, the reference -1.
    let block: [UInt8] = [16, 0xff, 0xff, 0, 1, 0xff, 0xff]
    var limits = Limits.defaults()
    limits.maxDepth = 8
    // The first block is the root object, with the reference 0.
    func nested(_ levels: Int) -> [UInt8] {
        preamble + [16, 0, 0, 0, 1, 0xff, 0xff] + [[UInt8]](repeating: block, count: levels - 1).joined() + [3, 0xff, 0xff, 0, 7]
    }
    var value = try parse(nested(7), options: ParseOptions(limits: limits)).root
    for _ in 0 ..< 7 {
        value = try #require(value.vector?.children.first)
    }
    #expect(value == .integer(7))
    expectError(containing: "object nesting exceeds 8") {
        try parse(nested(8), options: ParseOptions(limits: limits))
    }
}

/**
 Each cell of a list and each field of a record is one object of the
 file. Only the first one was counted, so the limit on the number of
 objects did not hold for a long list.
 */
@Test func `each cell of a list and each field of a record is counted`() throws {
    var limits = Limits.defaults()
    limits.maxObjects = 100
    let options = ParseOptions(limits: limits)
    #expect(throws: Never.self) { try parse(preamble + listStream(cells: 100), options: options) }
    expectError(containing: "object count exceeds 100") {
        try parse(preamble + listStream(cells: 101), options: options)
    }
    #expect(throws: Never.self) { try parse(preamble + recordStream(fields: 100), options: options) }
    expectError(containing: "object count exceeds 100") {
        try parse(preamble + recordStream(fields: 101), options: options)
    }
    // The count is the length of the list that was read.
    var length = 0
    var cell = try parse(preamble + listStream(cells: 100), options: options).root.pair
    var seen = Set<ObjectIdentifier>()
    while let current = cell, !current.empty, seen.insert(ObjectIdentifier(current)).inserted {
        length += 1
        cell = current.tail.pair
    }
    #expect(length == 100)
}

/** A block of bytes cannot be larger than the limit on one block. */
@Test func `a block of data larger than the limit is refused`() throws {
    var limits = Limits.defaults()
    limits.maxBlobBytes = 4
    // A byte string: kind 17, its reference, its size, its bytes.
    let text = Parser(data: [17, 0, 1, 0, 5] + Array("hello".utf8), options: ParseOptions(limits: limits))
    expectError(containing: "invalid allocation size 5") {
        try text.loadObject(1)
    }
    let short = Parser(data: [17, 0, 1, 0, 4] + Array("hell".utf8), options: ParseOptions(limits: limits))
    #expect(try short.loadObject(1).bytes == Array("hell".utf8))
}

/**
 A list of a million items is a chain of a million cells. Freed one
 from inside the other, the cells filled the stack. A cell that goes
 away now takes the rest of its chain apart in a loop; a cell that
 something else still uses is left as it is.
 */
@Test func `a long list or record is freed without deep recursion`() {
    var list: Pair? = Pair(empty: true)
    var record: Binding? = Binding(empty: true)
    for index in 0 ..< 1_000_000 {
        list = list.map { Pair(head: .integer(Int64(index)), tail: .pair($0)) }
        record = record.map { Binding(key: .integer(Int64(index)), next: .binding($0)) }
    }
    list = nil
    record = nil

    let shared = Pair(head: .integer(2), tail: .pair(Pair(head: .integer(3), tail: .pair(Pair(empty: true)))))
    var first: Pair? = Pair(head: .integer(1), tail: .pair(shared))
    #expect(first?.tail.pair === shared)
    first = nil
    #expect(shared.head == .integer(2) && shared.tail.pair?.head == .integer(3))
    #expect(shared.tail.pair?.tail.pair?.empty == true)
}
