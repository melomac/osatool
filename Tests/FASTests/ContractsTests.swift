import Extensions
@testable import FAS
import Testing

/**
 Makes a parser over `data`, in the state `FAS.parse` gives it: default
 limits, and an empty table of references.
 */
func contractParser(_ data: [UInt8]) -> Parser {
    Parser(data: data, options: ParseOptions(limits: .defaults()))
}

/**
 No reference is special. Reference 0 is the root object: Apple's writer
 gives the first number to the first object it stores. Before the root is
 loaded, 0 is not known, as any other number.
 */
@Test func `reference zero is the root object`() throws {
    let parser = contractParser([])
    #expect(parser.lookup(0) == nil)
    #expect(parser.lookup(1) == nil)

    // A root block with two items: the block itself, and the integer 7.
    //   0e 0000 0002  00  0000 ffff      value block, reference 0, two items
    //   03 ffff 0007                     the integer 7
    let data = Array("FasdUAS 1.101.10".utf8) + [0x0e, 0, 0, 0, 2, 0, 0, 0, 0xff, 0xff, 3, 0xff, 0xff, 0, 7]
    let document = try parse(data, options: ParseOptions())
    let root = try #require(document.root.vector)
    #expect(root.children.count == 3)
    #expect(root.children[1] == document.root, "the first item is the root itself")
    #expect(root.children[2] == .integer(7))
    #expect(document.diagnostics.isEmpty)
}

@Test func `primitive object contracts`() throws {
    // Case "symbol".
    do {
        var parser = contractParser([])
        #expect(try parser.loadBody(-1, 1, 0) == .null, "zero symbol")
        parser = contractParser([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
        expectError(containing: "must be zero") {
            try parser.loadBody(-1, 1, 8)
        }
    }

    // Case "immediate-size-errors".
    do {
        let parser = contractParser([])
        expectError(containing: "must be 4") {
            try parser.loadBody(-1, 7, 3)
        }
        expectError(containing: "must be 8") {
            try parser.loadBody(-1, 8, 4)
        }
    }

    // Case "long-and-float".
    do {
        let negative: Int32 = -2
        let data = bigEndian32(UInt32(bitPattern: negative)) + bigEndian64(3.25.bitPattern)
        let parser = contractParser(data)
        let integer = try parser.loadBody(-1, 7, 4)
        #expect(integer == .integer(-2))
        let real = try parser.loadBody(-1, 8, 8)
        #expect(real == .real(3.25))
    }

    // Case "unicode-text-and-style".
    do {
        let text: [UInt8] = [0, UInt8(ascii: "H"), 0, UInt8(ascii: "i")]
        let style: [UInt8] = [0, 0]
        let data = bigEndian16(text.count) + text + bigEndian16(style.count) + style
        let value = try contractParser(data).loadBody(-1, 12, UInt16(data.count))
        #expect(value == .object(.unicodeText(UnicodeText(text: text, style: style))))

        let invalidStyle: [UInt8] = [0, 0, 0, 2, 0, 1] + [UInt8](repeating: 0, count: 19)
        expectError(containing: "style table size") {
            try contractParser(invalidStyle).loadBody(-1, 12, 6)
        }
    }
}

@Test func `code identifier contracts`() throws {
    let valid: [(name: String, tag: UInt8, size: UInt16, data: String, want: UInt64)] = [
        ("eight-byte", 11, 8, "ABCDEFGH", 0x4142_4344_4546_4748),
        ("four-byte", 10, 4, "ABCD", 0x4142_4344),
        ("alternate-four-byte", 47, 4, "WXYZ", 0x5758_595a),
    ]
    for test in valid {
        let value = try contractParser([test.tag] + Array(test.data.utf8)).loadBody(-1, 10, test.size)
        #expect(value == .object(.constant(test.want)), "\(test.name)")
    }

    let wrongSizes: [(tag: UInt8, size: UInt16)] = [(11, 4), (10, 8), (46, 8)]
    for test in wrongSizes {
        #expect(throws: (any Error).self, "tag \(test.tag) size \(test.size) accepted") {
            try contractParser([test.tag]).loadBody(-1, 10, test.size)
        }
    }

    expectError(containing: "unknown code identifier tag") {
        try contractParser([0xff]).loadBody(-1, 10, 4)
    }
}

@Test func `data block contracts`() throws {
    let scriptData = Array("scptDATA".utf8)

    // Case "typed-short-and-long".
    do {
        let short = contractParser([13] + scriptData)
        var value = try short.loadBody(9, 15, 8)
        #expect(value == .rawData(scriptData), "short data")
        #expect(short.lookup(9) == value, "short data was not registered")

        let data: [UInt8] = [13] + bigEndian32(8) + scriptData
        value = try contractParser(data).loadBody(-1, 18, 0)
        #expect(value == .rawData(scriptData), "long data")
    }

    // Case "untyped-short-and-long".
    do {
        var value = try contractParser(Array("hello".utf8)).loadBody(-1, 17, 5)
        #expect(value == .bytes(Array("hello".utf8)), "short bytes")
        let data = bigEndian32(5) + Array("world".utf8)
        value = try contractParser(data).loadBody(-1, 19, 0)
        #expect(value == .bytes(Array("world".utf8)), "long bytes")
    }

    // Case "descriptor".
    do {
        let content = Array("payload".utf8)
        var data: [UInt8] = [8] + [UInt8](repeating: 0, count: 82)
        data += [UInt8](repeating: 0, count: 8)
        data += Array("alis".utf8)
        data += content
        let parser = contractParser(data)
        let value = try parser.loadBody(3, 15, UInt16(94 + content.count))
        #expect(value == .descriptor(Descriptor(type: "alis", content: content)))
        #expect(parser.lookup(3) == value, "descriptor was not registered")
    }
}

@Test func `user identifier contracts`() throws {
    func encode(_ key: String, _ value: String) -> [UInt8] {
        var data: [UInt8] = [48]
        data += bigEndian16(key.utf8.count)
        data += Array(key.utf8)
        data += bigEndian16(value.utf8.count)
        data += Array(value.utf8)
        return data
    }
    let tests: [(key: String, value: String, want: String)] = [
        ("sourceName", "compiledName", "compiledName"),
        ("sourceName", "", "sourceName"),
    ]
    for test in tests {
        let encoded = encode(test.key, test.value)
        let value = try contractParser(encoded).loadBody(-1, 11, UInt16(encoded.count - 1))
        #expect(value == .bytes(Array(test.want.utf8)))
    }

    #expect(throws: (any Error).self, "invalid marker accepted") {
        try contractParser([0]).loadBody(-1, 11, 0)
    }
    let oversized: [UInt8] = [48, 1, 0] + [UInt8](repeating: UInt8(ascii: "a"), count: 256) + [0, 0]
    #expect(throws: (any Error).self, "oversized identifier accepted") {
        try contractParser(oversized).loadBody(-1, 11, 0)
    }
}

@Test func `composite object contracts`() throws {
    // Case "value-block-and-pointer-order".
    do {
        var parser = contractParser([15])
        var value = try parser.loadBody(5, 4, 0)
        #expect(value == .secondActor)
        #expect(parser.lookup(5) == .secondActor, "actor not registered")

        parser = contractParser([4, 0, 2, 0, 3])
        try parser.register(2, .integer(10))
        try parser.register(3, .integer(20))
        value = try parser.loadBody(6, 4, 2)
        let vector = try #require(value.vector)
        #expect(vector.type == 4)
        try #require(vector.children.count == 3)
        #expect(vector.children[1] == .integer(10))
        #expect(vector.children[2] == .integer(20))

        parser = contractParser([0, 4, 0, 5])
        try parser.register(4, .integer(1))
        try parser.register(5, .integer(2))
        value = try parser.loadBody(8, 16, 2)
        let children = try #require(value.vector).children
        try #require(children.count == 2)
        #expect(children[0] == .integer(1))
        #expect(children[1] == .integer(2))
    }

    // Case "statement".
    do {
        let parser = contractParser([9, 0, 10, 0, 20, 0, 30, 0, 4, 0, 5])
        try parser.register(4, .integer(1))
        try parser.register(5, .integer(2))
        let value = try parser.loadBody(7, 13, 2)
        guard case let .statement(statement) = value else {
            Issue.record("the value is \(value.typeName), want statement")
            return
        }
        #expect(statement.tag == 9)
        #expect(statement.typeInfo == 10)
        #expect(statement.start == 20)
        #expect(statement.end == 30)
        try #require(statement.children.count == 5)
        #expect(statement.children[3] == .integer(1))
        #expect(statement.children[4] == .integer(2))
    }

    // Case "empty-and-linked-list".
    do {
        var value = try contractParser([]).loadBody(-1, 2, 0)
        #expect(value.pair?.empty == true, "empty list")

        let parser = contractParser([0, 1, 0, 2])
        try parser.register(1, .integer(1))
        let tail = Value.pair(Pair(head: .integer(2), tail: .pair(Pair(empty: true))))
        try parser.register(2, tail)
        value = try parser.loadBody(-1, 2, 2)
        let head = try #require(value.pair)
        #expect(head.head == .integer(1))
        // Two containers are equal only when they are the same object.
        #expect(head.tail == tail, "the tail is not the registered object")
    }

    // Case "record-shapes".
    do {
        var value = try contractParser([]).loadBody(-1, 6, 0)
        #expect(value.binding?.empty == true, "empty record")
        #expect(throws: (any Error).self, "unknown record shape accepted") {
            try contractParser([]).loadBody(-1, 6, 2)
        }

        let parser = contractParser([0, 1, 0, 2, 0, 3])
        try parser.register(1, .bytes(Array("alpha".utf8)))
        try parser.register(2, .integer(9))
        try parser.register(3, .null)
        value = try parser.loadBody(12, 6, 3)
        let head = try #require(value.binding)
        #expect(head.key == .bytes(Array("alpha".utf8)))
        #expect(head.value == .integer(9))
        #expect(head.next == .null)
        #expect(parser.lookup(12) == value, "record head was not registered")
    }
}

@Test func `parser resource limits`() throws {
    let preamble = Array("FasdUAS 1.10".utf8) + Array("1.10".utf8)
    let data = preamble + [3, 0, 0, 0, 1]
    #expect(throws: (any Error).self, "input limit was not enforced") {
        try parse(data, options: ParseOptions(limits: Limits(maxInputBytes: 4)))
    }
    expectError(containing: "unknown FAS object type 255") {
        try contractParser([]).loadBody(-1, 255, 0)
    }
    let value = try contractParser([0xfe, 0xaa, 0xbb]).loadBody(-1, 15, 2)
    #expect(value == .typedData(TypedData(type: 0xfe, data: [0xaa, 0xbb])), "unknown runtime value")
}
