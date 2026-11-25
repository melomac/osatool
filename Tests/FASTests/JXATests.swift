import Extensions
@testable import FAS
import Foundation
import Testing
import TestSupport

/**
 The fixtures of `testdata/jxa` were made with `osacompile -l JavaScript`.
 The text of `unicode.js` is not ASCII, so the property list holds it as
 UTF-16, and it has no newline at its end: none is added.
 */
@Test(arguments: ["hello", "unicode"])
func `the source of a JXA script is the stored text`(name: String) throws {
    let script = try TestData.bytes("jxa/\(name).scpt")
    #expect(isJavaScript(script))
    #expect(try javaScriptSource(script) == TestData.text("jxa/\(name).js"))
}

/** `osacompile -x` writes the same bytes: a run-only JXA script keeps its source. */
@Test func `a run-only JXA script is the same file`() throws {
    #expect(try TestData.bytes("jxa/hello-run-only.scpt") == TestData.bytes("jxa/hello.scpt"))
}

@Test func `an AppleScript is not a JXA script`() throws {
    #expect(try !isJavaScript(TestData.bytes("demo.scpt")))
    #expect(!isJavaScript([]))
    #expect(!isJavaScript(Array("JsOsa".utf8)))
    // A `#!` line with no end: the parser of AppleScript says so.
    #expect(!isJavaScript(Array("#!/usr/bin/osascript JsOsaDAS".utf8)))
    expectError(containing: "invalid JXA magic \"FasdUAS \"") {
        try javaScriptSource(TestData.bytes("demo.scpt"))
    }
}

/**
 What `osadecompile` reads, the tool reads too: a property list in any
 of its three forms, with other keys, after a `#!` line, with more
 padding, and with another version.
 */
@Test func `a JXA script in every form the system loads`() throws {
    let source = "1 // one\n"
    let binary = try TestData.propertyList(["script": source])
    let forms: [(String, [UInt8])] = try [
        ("binary", TestData.javaScript(propertyList: binary)),
        ("XML", TestData.javaScript(propertyList: TestData.propertyList(["script": source], format: .xml))),
        ("old text", TestData.javaScript(propertyList: Array(#"{ script = "1 // one\n"; }"#.utf8))),
        ("other keys", TestData.javaScript(propertyList: TestData.propertyList(["a": 1, "script": source, "z": [1, 2]]))),
        ("hashbang", Array("#!/usr/bin/osascript\n".utf8) + TestData.javaScript(propertyList: binary)),
        ("no padding", TestData.javaScript(propertyList: binary, padding: 0)),
        ("more padding", TestData.javaScript(propertyList: binary, padding: 5)),
        ("another version", Array("JsOsaDAS2.001.00".utf8) + TestData.javaScript(propertyList: binary).dropFirst(16)),
    ]
    for (name, script) in forms {
        #expect(isJavaScript(script), "\(name)")
        #expect(try javaScriptSource(script) == source, "\(name)")
    }
    #expect(try javaScriptSource(TestData.javaScript(propertyList: TestData.propertyList(["script": ""]))).isEmpty)
}

/** A file cut at any place is refused with an error, and the reader never goes past the end. */
@Test func `a JXA script cut short is refused`() throws {
    let script = try TestData.bytes("jxa/hello.scpt")
    for count in 8 ..< script.count {
        #expect(throws: ScriptError.self, "\(count) bytes") {
            try javaScriptSource(Array(script.prefix(count)))
        }
    }
    expectError(containing: "read JXA trailer at 0x14: unexpected end of data") {
        try javaScriptSource(Array(script.prefix(20)))
    }
    expectError(containing: "invalid JXA trailer magic \"}\\n\\b\\v\" at 0x4e") {
        try javaScriptSource(Array(script.prefix(0x52)))
    }
    // The end of the property list is lost, and the trailer is there.
    expectError(containing: "read JXA property list at 0x10: damaged property list") {
        try javaScriptSource(Array(script.prefix(0x52) + script.suffix(12)))
    }
}

@Test func `a JXA script with a damaged property list is refused`() throws {
    var script = try TestData.bytes("jxa/hello.scpt")
    // The last byte of the property list says where its table of offsets is.
    #expect(script[0x72] == 0x40)
    script[0x72] = 0xf0
    let damaged = [
        script,
        TestData.javaScript(propertyList: []),
        TestData.javaScript(propertyList: Array("<plist><dict><key>script</key><string>1</str".utf8)),
        TestData.javaScript(propertyList: Array(#"{ "script" : "1" }"#.utf8)),
    ]
    for script in damaged {
        expectError(containing: "read JXA property list at 0x10: damaged property list") {
            try javaScriptSource(script)
        }
    }
    // The start of the binary form alone is a word of the old text form.
    expectError(containing: "JXA property list is not a dictionary") {
        try javaScriptSource(TestData.javaScript(propertyList: Array("bplist00".utf8)))
    }
}

@Test func `a JXA script with no source text is refused`() {
    let cases: [(Any, String)] = [
        (["source": "1"], "JXA property list has no \"script\" key"),
        ([String: Any](), "JXA property list has no \"script\" key"),
        (["script": Data("1".utf8)], "JXA \"script\" value is not text"),
        (["script": 1], "JXA \"script\" value is not text"),
        (["script": ["1"]], "JXA \"script\" value is not text"),
        (["script", "1"], "JXA property list is not a dictionary"),
        ("1", "JXA property list is not a dictionary"),
    ]
    for (value, want) in cases {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            expectError(containing: want) {
                try javaScriptSource(TestData.javaScript(propertyList: TestData.propertyList(value, format: format)))
            }
        }
    }
}

/** The size in the trailer says where the property list ends: it must fit in the file. */
@Test func `the trailer of a JXA script is checked`() throws {
    let script = try TestData.bytes("jxa/hello.scpt")
    let sizeOffset = script.count - 6
    for (size, want) in [(0, "invalid JXA trailer size 0 at 0x7a"), (11, "size 11"), (113, "size 113"), (0xffff, "size 65535")] {
        var changed = script
        changed.replaceSubrange(sizeOffset ..< sizeOffset + 2, with: bigEndian16(size))
        expectError(containing: want) {
            try javaScriptSource(changed)
        }
    }
    // The largest size that fits leaves an empty property list.
    var changed = script
    changed.replaceSubrange(sizeOffset ..< sizeOffset + 2, with: bigEndian16(112))
    expectError(containing: "damaged property list") {
        try javaScriptSource(changed)
    }
    changed = script
    changed[script.count - 1] = 0
    expectError(containing: "invalid JXA trailer magic \"\\xfa\\xde\\xde\\x00\" at 0x7c") {
        try javaScriptSource(changed)
    }
}

@Test func `a JXA script over the size limit is refused`() throws {
    let script = try TestData.bytes("jxa/hello.scpt")
    #expect(try javaScriptSource(script, limits: Limits(maxInputBytes: script.count)) == TestData.text("jxa/hello.js"))
    expectError(containing: "JXA stream exceeds 127-byte limit") {
        try javaScriptSource(script, limits: Limits(maxInputBytes: script.count - 1))
    }
}
