import Extensions
import Testing

@Test func `real formatting`() {
    let cases: [(UInt64, String)] = [
        (0x0000_0000_0000_0000, "0"),
        (0x8000_0000_0000_0000, "-0"),
        (0x3ff0_0000_0000_0000, "1"),
        (0xbff0_0000_0000_0000, "-1"),
        (0x4008_0000_0000_0000, "3"),
        (0x3ff8_0000_0000_0000, "1.5"),
        (0x3fb9_9999_9999_999a, "0.1"),
        (0x40f8_6a00_0000_0000, "100000"),
        (0x412e_847e_0000_0000, "999999"),
        (0x412e_8480_0000_0000, "1e+06"),
        (0x4132_d687_0000_0000, "1.234567e+06"),
        (0x4167_8c29_d000_0000, "1.23456785e+07"),
        (0x4415_af1d_78b5_8c40, "1e+20"),
        (0x444b_1ae4_d6e2_ef50, "1e+21"),
        (0x4454_542b_a12a_337c, "1.5e+21"),
        (0x4480_f0cf_064d_d592, "1e+22"),
        (0x3f1a_36e2_eb1c_432d, "0.0001"),
        (0x3f20_2e4b_6ce5_dc68, "0.00012345"),
        (0x3ee4_f8b5_88e3_68f1, "1e-05"),
        (0x3e84_21f5_f40d_8376, "1.5e-07"),
        (0x0000_0000_0000_0001, "5e-324"),
        (0x7fef_ffff_ffff_ffff, "1.7976931348623157e+308"),
        (0x419d_6f34_5400_0000, "1.23456789e+08"),
        (0x3fe0_0000_0000_0000, "0.5"),
        (0x3efa_36e2_eb1c_432d, "2.5e-05"),
        (0x40fe_240b_3333_3333, "123456.7"),
        (0x4009_21f9_f01b_866e, "3.14159"),
        (0xc217_4876_e800_0000, "-2.5e+10"),
        (0x7ff0_0000_0000_0000, "+Inf"),
        (0xfff0_0000_0000_0000, "-Inf"),
        (0x7ff8_0000_0000_0001, "NaN"),
        (0x4059_0000_0000_0000, "100"),
        (0x430c_6bf5_2634_0000, "1e+15"),
        (0x4341_c379_37e0_8000, "1e+16"),
        (0x4376_3457_85d8_a000, "1e+17"),
        (0x3f06_0525_02ee_c7c9, "4.2e-05"),
        (0x4028_0000_0000_0000, "12"),
    ]
    for (bits, want) in cases {
        #expect(Double(bitPattern: bits).shortestDescription == want, "bits \(String(bits, radix: 16))")
    }
}

/** Each case is the bytes to quote, as hexadecimal, and the expected text. */
@Test func quoting() throws {
    let cases: [(String, String)] = [
        ("", "\"\""),
        ("616263", "\"abc\""),
        ("6122625c63", "\"a\\\"b\\\\c\""),
        ("7461620968657265", "\"tab\\there\""),
        ("6e6c0a", "\"nl\\n\""),
        ("00017f", "\"\\x00\\x01\\x7f\""),
        ("636166c3a9", "\"café\""),
        ("c2a06e627370", "\"\\u00a0nbsp\""),
        ("e280a86c73", "\"\\u2028ls\""),
        ("efa3bf", "\"\\uf8ff\""),
        ("f09f9880", "\"😀\""),
        ("626164fffe6279746573", "\"bad\\xff\\xfebytes\""),
        ("e282", "\"\\xe2\\x82\""),
        ("e282ac", "\"€\""),
        ("07080c0d0b", "\"\\a\\b\\f\\r\\v\""),
        ("c2ad", "\"\\u00ad\""),
        ("e2808b", "\"\\u200b\""),
        ("efbfbd", "\"\u{FFFD}\""),
        ("65cc81", "\"e\u{301}\""),
    ]
    for (hex, want) in cases {
        let bytes = try #require([UInt8](hex: hex))
        #expect(bytes.quoted == want, "bytes \(hex)")
    }
}

@Test func `hex helpers`() {
    #expect(([0x0a, 0xff] as [UInt8]).hex == "0aff")
    #expect([UInt8](hex: "0AfF") == [0x0a, 0xff])
    #expect([UInt8](hex: "abc") == nil)
    #expect([UInt8](hex: "zz") == nil)
    #expect(255.hex == "ff")
    #expect(5.hex(width: 5) == "00005")
    #expect(UInt8(0x0f).hex(width: 2) == "0f")
}

@Test func padding() {
    #expect("ab".padded(to: 5) == "ab   ")
    #expect("abcdef".padded(to: 5) == "abcdef")
}

@Test func `scalar classes`() {
    #expect(("é" as Unicode.Scalar).isLetter)
    #expect(!("1" as Unicode.Scalar).isLetter)
    #expect(("٣" as Unicode.Scalar).isDecimalDigit)
    #expect((" " as Unicode.Scalar).isPrintable)
    #expect(!("\u{00A0}" as Unicode.Scalar).isPrintable)
    #expect(!("\n" as Unicode.Scalar).isPrintable)
}

@Test func `error messages`() {
    #expect(ScriptError("boom").message == "boom")
    #expect(String(describing: ScriptError("boom")) == "boom")
}

@Test func `printable ASCII bytes`() {
    #expect(Array("pnam ~".utf8).isPrintableASCII)
    #expect(([] as [UInt8]).isPrintableASCII)
    #expect(![0x41, 0x0a].isPrintableASCII)
    #expect(![0x41, 0x7f].isPrintableASCII)
    #expect(![0xc3, 0xa9].isPrintableASCII)
}

@Test func `UTF-16 big-endian text`() {
    #expect(String(utf16BigEndian: [0x00, 0x68, 0x00, 0x69]) == "hi")
    #expect(String(utf16BigEndian: [0xd8, 0x3d, 0xde, 0x00]) == "😀")
    // A high surrogate alone is damaged text.
    #expect(String(utf16BigEndian: [0xd8, 0x3d, 0x00, 0x41]) == "\u{FFFD}A")
    // The last byte of an odd count is ignored.
    #expect(String(utf16BigEndian: [0x00, 0x68, 0x00]) == "h")
    #expect(String(utf16BigEndian: []) == "")
}

/** The line printed for a diagnostic names the stage, and the position when there is one. */
@Test func `diagnostic description`() {
    let located = Diagnostic(stage: .parse, offset: 0xa1, message: "RefID mismatch: expected 2, found 7")
    #expect(located.description == "parse at 0xa1: RefID mismatch: expected 2, found 7")
    #expect(located.function == nil && located.opcode == nil)

    // Offset 0 is a position: the first instruction of a function.
    let first = Diagnostic(stage: .decode, function: 2, offset: 0, opcode: 97, message: "truncated operand")
    #expect(first.description == "decode at 0x0: truncated operand")

    let general = Diagnostic(stage: .decompile, function: 3, message: "expression stack underflow")
    #expect(general.description == "decompile: expression stack underflow")
}

/** A code written as a string literal has the bytes of its characters. */
@Test func `codes from string literals`() {
    let name: Code4 = "pnam"
    #expect(name.rawValue == 0x706e_616d)
    #expect(name.bytes == Array("pnam".utf8))
    #expect(name == Code4(bytes: "pnam".utf8))
    #expect(name != "pnan")

    let run: EventCode = "aevtoapp"
    #expect(run.rawValue == 0x6165_7674_6f61_7070)
    #expect(run.first == "aevt")
    #expect(run.second == "oapp")
    #expect(run == EventCode(first: "aevt", second: "oapp"))

    // A literal works as a dictionary key and in a `switch`.
    let words: [Code4: String] = ["to  ": "to", "by  ": "by"]
    #expect(words[Code4(bytes: "by  ".utf8)] == "by")
    switch name {
    case "pnam":
        break
    default:
        Issue.record("the code did not match its literal")
    }
}

@Test func `saturating addition`() {
    #expect(2.addingSaturating(3) == 5)
    #expect((-2).addingSaturating(-3) == -5)
    #expect(Int.max.addingSaturating(1) == .max)
    #expect((Int.max - 1).addingSaturating(Int.max) == .max)
    #expect(Int.min.addingSaturating(-1) == .min)
    #expect(Int.max.addingSaturating(Int.min) == -1)
}
