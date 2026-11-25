import AST
@testable import Decompilation
import Extensions
import FAS
import Foundation
import Testing

/**
 Packs bytes into one number, first byte in the highest position.

 With 8 bytes this is a big-endian 64-bit number.
 */
private func packed(_ bytes: [UInt8]) -> UInt64 {
    var value: UInt64 = 0
    for byte in bytes {
        value = value << 8 | UInt64(byte)
    }
    return value
}

private func packed(_ text: String) -> UInt64 {
    packed(Array(text.utf8))
}

/**
 Returns an alias record of 80 bytes with a valid version (`0 2`) and the
 given target name.
 */
private func aliasRecord(_ name: String) -> [UInt8] {
    var record = [UInt8](repeating: 0, count: 80)
    record[7] = 2
    record[50] = UInt8(name.utf8.count)
    record.replaceSubrange(51 ..< 51 + name.utf8.count, with: name.utf8)
    return record
}

@Test func `literal primitive contracts`() {
    let cases: [(name: String, value: Value, check: (any Expr) -> Bool)] = [
        ("nil", .null, { $0 is MissingLiteral }),
        ("true", .special(Special.true), { value in
            guard let got = value as? BooleanLiteral else { return false }
            return got.value
        }),
        ("false", .special(Special.false), { value in
            guard let got = value as? BooleanLiteral else { return false }
            return !got.value
        }),
        ("integer", .integer(-2935), { value in
            guard let got = value as? NumberLiteral else { return false }
            return got.integer == -2935
        }),
        ("integer over 32767", .integer(64104), { value in
            guard let got = value as? NumberLiteral else { return false }
            return got.integer == 64104
        }),
        ("float", .real(3.25), { value in
            guard let got = value as? NumberLiteral else { return false }
            return got.isReal && got.real == 3.25
        }),
        ("bytes", bytes("text"), { value in
            guard let got = value as? StringLiteral else { return false }
            return got.value == "text"
        }),
        ("unicode", .unicodeText(UnicodeText(text: [0, UInt8(ascii: "H"), 0, UInt8(ascii: "i")])), { value in
            guard let got = value as? StringLiteral else { return false }
            return got.value == "Hi"
        }),
    ]
    for test in cases {
        let got = test.value.literal
        #expect(test.check(got), "literal(\(test.value.typeName)), case \(test.name)")
    }
}

@Test func `packed constant contracts`() throws {
    let current = KeywordCode(packed: packed("misccura")).literal
    try #require(current is CurrentApplication, "current application")
    let packedConstant = KeywordCode(packed: packed("EAlTcriT")).literal
    var keyword = packedConstant as? Keyword
    try #require(keyword?.code == .eight("EAlTcriT"), "packed constant")
    let unknown = KeywordCode(packed: packed(Array("test".utf8) + [0, 0, 0, 1])).literal
    keyword = try #require(unknown as? Keyword)
    try #require(keyword?.code?.bytes.count == 8 && keyword?.code?.bytes[7] == 1, "unknown packed constant")
}

@Test func `unknown packed constant preserves type and member`() throws {
    let value = packed("testABCD")
    let keyword = KeywordCode(packed: value).literal as? Keyword
    try #require(keyword?.code == .eight("testABCD"), "packed constant")
    let formatted = AST.format(Script(handlers: [Handler(
        name: "probe", body: [Return(value: keyword, explicit: true)],
    )]), terms: nil)
    try #require(formatted.contains("return «constant testABCD»"), "packed constant source")
}

@Test func `list and record literal contracts`() throws {
    let list = Value.pair(Pair(head: .integer(9), tail: .pair(Pair(head: .integer(1), tail: .pair(Pair(empty: true))))))
    let gotList = try #require(list.literal as? List)
    try #require(gotList.elements.count == 2, "list")
    try #require(
        try #require(gotList.elements[0] as? NumberLiteral).integer == 9
            && (try #require(gotList.elements[1] as? NumberLiteral)).integer == 1,
        "list",
    )

    let second = Value.binding(Binding(key: bytes("b"), value: .integer(7)))
    let first = Value.binding(Binding(key: bytes("a"), value: .integer(9), next: second))
    let gotRecord = try #require(first.literal as? Record)
    try #require(gotRecord.fields.count == 2, "record")
    try #require(
        try #require(gotRecord.fields[0].label as? StringLiteral).value == "a"
            && (try #require(gotRecord.fields[1].value as? NumberLiteral)).integer == 7,
        "record",
    )
}

@Test func `raw data and long date contracts`() throws {
    let raw = try #require(Value.rawData(Array("scptFasd".utf8)).literal as? RawDataLiteral)
    try #require(String(decoding: raw.type.bytes, as: UTF8.self) == "scpt" && String(decoding: raw.data, as: UTF8.self) == "Fasd", "raw data")
    let unknown = try #require(Value.rawData([0, 1, 2, 3, UInt8(ascii: "x")]).literal as? RawDataLiteral)
    try #require(String(decoding: unknown.type.bytes, as: UTF8.self) == "****" && unknown.data.count == 5, "unknown raw data")

    var epoch = [UInt8](repeating: 0, count: 8)
    var date = Value.descriptor(Descriptor(type: "ldt ", content: epoch)).literal
    try #require((date as? DateLiteral)?.value == "Friday, January 1, 1904 at 12:00:00\u{202F}AM", "descriptor date")

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = try #require(TimeZone(identifier: "UTC"))
    let start = try #require(utc.date(from: DateComponents(year: 1904, month: 1, day: 1)))
    let end = try #require(utc.date(from: DateComponents(year: 2025, month: 1, day: 1)))
    let seconds = UInt64(end.timeIntervalSince(start))
    epoch = (0 ..< 8).map { UInt8(truncatingIfNeeded: seconds >> (56 - 8 * UInt64($0))) }
    date = Value.rawData(Array("ldt ".utf8) + epoch).literal
    try #require((date as? DateLiteral)?.value == "Wednesday, January 1, 2025 at 12:00:00\u{202F}AM", "raw date")
}

/** `aliasName` returns `nil` for a record it does not accept. */
@Test func `alias name contracts`() throws {
    let descriptor = aliasRecord("System Settings.app")
    try #require(descriptor.aliasTargetName == "System Settings", "alias name")
    try #require(Array("Disk:Folder:Extensionless".utf8).aliasTargetName == nil, "malformed alias")
}

@Test func `only validated alias descriptors become applications`() throws {
    var content = aliasRecord("Finder.app")
    let application = Value.descriptor(Descriptor(type: "alis", content: content)).literal as? Application
    try #require(application != nil && application?.name == "Finder", "validated alias")
    let raw = Value.descriptor(Descriptor(type: "book", content: content)).literal as? RawDataLiteral
    try #require(raw != nil && String(decoding: raw?.type.bytes ?? [], as: UTF8.self) == "book", "non-alias descriptor")
    content[7] = 1
    try #require(
        !(Value.descriptor(Descriptor(type: "alis", content: content)).literal is Application),
        "malformed alias descriptor became an application target",
    )
}

@Test func `identifier recovery contracts`() throws {
    try #require(bytes("process_name").identifier(or: "fallback") == "process_name", "valid identifier")
    try #require(bytes("not valid").identifier(or: "arg_0") == "not valid", "fallback identifier")
    try #require(!"9invalid".isPlainIdentifier && "_valid9".isPlainIdentifier, "identifier validity contract failed")
    let path = Value.object(.constant(0x4654_5063))
    try #require(path.identifier(or: "arg_0") == "path", "runtime-object identifier, want path")
    let cases: [(code: String, want: String)] = [
        ("pnam", "name"),
        ("vers", "version"),
    ]
    for (code, want) in cases {
        let value = packed(code)
        try #require(
            Value.object(.constant(value)).identifier(or: "fallback") == want,
            "runtime-object identifier \(code), want \(want)",
        )
    }
}

@Test func `apple script special constants`() {
    let cases: [(code: String, want: String)] = [
        ("FTPc", "path"),
        ("lnfd", "linefeed"),
        ("prun", "running"),
        ("rslt", "result"),
        ("spac", "space"),
        ("strq", "quoted form"),
    ]
    for (code, want) in cases {
        let value = packed(code)
        let keyword = KeywordCode(packed: value).literal as? Keyword
        #expect(keyword != nil && keyword?.fallback == want, "\(code), want fallback \(want)")
    }
}

@Test func `unicode wrapper preserves damaged ASCII payload`() throws {
    let value = Value.vector(Vector(type: 177, hasType: true, children: [.null, bytes("/dev/disk")]))
    var got = value.literal as? StringLiteral
    try #require(got != nil && got?.value == "/dev/disk", "want printable ASCII string")

    let utf16 = Value.vector(Vector(type: 177, hasType: true, children: [.null, .bytes([0, UInt8(ascii: "o"), 0, UInt8(ascii: "k")])]))
    got = utf16.literal as? StringLiteral
    try #require(got != nil && got?.value == "ok", "want UTF-16BE string")

    // Two printable bytes are one character, not two: 20 26 is "…".
    let ellipsis = Value.vector(Vector(type: 177, hasType: true, children: [.null, .bytes([0x20, 0x26, 0x20, 0x22])]))
    #expect((ellipsis.literal as? StringLiteral)?.value == "…•")
}

/**
 The text of a date is the one Apple's tools print in the locale
 `en_US_POSIX`. Each pair here is a date as `osacompile` stored it, and
 the text `osadecompile` printed for it.

 A day before 15 October 1582 is a date of the Julian calendar: the
 last four dates were typed as 1/1/1000, 6/15/800, 10/9/1582 (a day
 that calendar reform left out) and 1/1/100.
 */
@Test func `a date is written as Apple writes it in the United States`() {
    let cases: [(stored: UInt64, text: String)] = [
        (0x0000_0000_0000_0000, "Friday, January 1, 1904 at 12:00:00 AM"),
        (0x0000_003b_7c19_f1ff, "Friday, December 31, 9999 at 11:59:59 PM"),
        (0xffff_ffff_1033_4fcb, "Thursday, July 4, 1776 at 1:02:03 PM"),
        (0x0000_0000_da86_9a40, "Thursday, March 5, 2020 at 12:00:00 PM"),
        (0x0000_0000_da85_f888, "Thursday, March 5, 2020 at 12:30:00 AM"),
        (0x0000_0000_b4e1_3c43, "Tuesday, February 29, 2000 at 9:05:07 AM"),
        (0xffff_fff9_5ba9_5480, "Monday, January 1, 1000 at 12:00:00 AM"),
        (0xffff_fff7_e452_0680, "Monday, June 15, 800 at 12:00:00 AM"),
        (0xffff_fffd_a3d7_5a00, "Tuesday, October 19, 1582 at 12:00:00 AM"),
        (0xffff_fff2_bec7_a500, "Wednesday, January 1, 100 at 12:00:00 AM"),
        // The first and the last date that have a text.
        (0xffff_fff2_0491_1680, "Saturday, January 1, 1 at 12:00:00 AM"),
        (0x0000_a73d_e381_11e0, "Monday, December 19, 5828963 at 2:00:00 PM"),
    ]
    for (stored, text) in cases {
        let bytes = (0 ..< 8).map { UInt8(truncatingIfNeeded: stored >> (56 - 8 * UInt64($0))) }
        // Apple puts a narrow no-break space before AM and PM.
        let want = text.replacingOccurrences(of: " AM", with: "\u{202F}AM").replacingOccurrences(of: " PM", with: "\u{202F}PM")
        #expect(DateLiteral(longDate: bytes)?.value == want, "\(text)")
    }
    #expect(DateLiteral(longDate: [0, 0, 0]) == nil)
}

/**
 A date before year 1 has no text that reads back as the same date:
 Apple's tools print 31 December of 1 BC as `Friday, December 31, 1`.
 A very far date has no text at all: they print `date ""`.

 Such a date is written as raw data. The compiler stores the bytes of
 `«data ldt …»` in the opposite order, so they are written last byte
 first. `osacompile` made a date with the bytes `8B 0F 3E 6A CD FF FF FF`
 from the first text here.

 The fuzzer found the far dates: the tool stopped on them.
 */
@Test func `a date with no text is written as raw data`() throws {
    let cases: [(stored: [UInt8], text: String)] = [
        ([0x8b, 0x0f, 0x3e, 0x6a, 0xcd, 0xff, 0xff, 0xff], "«data ldt FFFFFFCD6A3E0F8B»"),
        // One second before year 1, and one second after the last text.
        ([0xff, 0xff, 0xff, 0xf2, 0x04, 0x91, 0x16, 0x7f], "«data ldt 7F169104F2FFFFFF»"),
        ([0x00, 0x00, 0xa7, 0x3d, 0xe3, 0x81, 0x11, 0xe1], "«data ldt E11181E33DA70000»"),
        // The dates of the three files the fuzzer kept.
        ([0xb4, 0x00, 0xe1, 0x00, 0x3c, 0x00, 0x00, 0x43], "«data ldt 4300003C00E100B4»"),
        ([0xff, 0xff, 0xf5, 0xfd, 0xa3, 0xd2, 0x14, 0x00], "«data ldt 0014D2A3FDF5FFFF»"),
        ([0xff, 0xf7, 0xff, 0xfd, 0xa3, 0xd2, 0x14, 0x00], "«data ldt 0014D2A3FDFFF7FF»"),
        // The smallest and the largest count.
        ([0x80, 0, 0, 0, 0, 0, 0, 0], "«data ldt 0000000000000080»"),
        ([0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], "«data ldt FFFFFFFFFFFFFF7F»"),
    ]
    for (stored, text) in cases {
        #expect(DateLiteral(longDate: stored) == nil, "\(text)")
        // The two ways a file holds a date.
        let literals = [
            Value.rawData(Array("ldt ".utf8) + stored).literal,
            Value.descriptor(Descriptor(type: "ldt ", content: stored)).literal,
        ]
        for literal in literals {
            let raw = try #require(literal as? RawDataLiteral, "\(text)")
            #expect(raw.type == "ldt ")
            #expect(text == "«data ldt \(raw.data.hex.uppercased())»")
        }
    }
    // Not 8 bytes: not a date, and the bytes stay in their order.
    #expect([UInt8]([0, 0, 0]).longDateLiteral == nil)
    let short = try #require(Value.rawData(Array("ldt ".utf8) + [1, 2, 3]).literal as? RawDataLiteral)
    #expect(short.data == [1, 2, 3])
}

/** The two calendars meet between 4 and 15 October 1582. */
@Test func `the calendar changes in October 1582`() {
    #expect(Int64(0).civilDate == (1970, 1, 1))
    #expect(Int64(-141_427).civilDate == (1582, 10, 15))
    #expect(Int64(-141_428).civilDate == (1582, 10, 4))
    #expect(Int64(-141_428 - 276).civilDate == (1582, 1, 1))
    #expect(Int64(11016).civilDate == (2000, 2, 29))
}

/**
 Days far in the past: the first two are the Julian day 0 and the day
 before it, the third one is a day Apple's tools print as
 `Wednesday, March 20, 4987` (4987 BC, the year -4986 of astronomers).
 The last one is the earliest day a long date can hold.
 */
@Test func `a day before the Julian day 0 has a date`() {
    #expect(Int64(-2_440_588).civilDate == (-4712, 1, 1))
    #expect(Int64(-2_440_589).civilDate == (-4713, 12, 31))
    #expect(Int64(-2_540_588).civilDate == (-4986, 3, 20))
    #expect(Int64(-719_164).civilDate == (1, 1, 1))
    #expect(Int64(-719_165).civilDate == (0, 12, 31))
    let earliest = (Int64.min / 86400 - 1 - 24107).civilDate
    #expect((1 ... 12).contains(earliest.month) && (1 ... 31).contains(earliest.day))
}

/**
 Text with a style table is styled text, which old versions of Script
 Editor wrote: its bytes are MacRoman. Without the table they are UTF-16.
 */
@Test func `styled text is MacRoman`() {
    let cafe: [UInt8] = [0x63, 0x61, 0x66, 0x8e]
    let styled = Value.object(.unicodeText(UnicodeText(text: cafe, style: [0, 0])))
    #expect((styled.literal as? StringLiteral)?.value == "café")
    let plain = Value.object(.unicodeText(UnicodeText(text: [0, 0x41, 0, 0xe9])))
    #expect((plain.literal as? StringLiteral)?.value == "Aé")
}
