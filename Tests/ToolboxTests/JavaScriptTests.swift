import Foundation
import OSAToolbox
import Testing
import TestSupport

/**
 A JavaScript for Automation (JXA) script through the library. The
 reader itself is tested with the target `FAS`.
 */
@Test func `the library gives the source of a JXA script`() throws {
    let script = try TestData.bytes("jxa/hello.scpt")
    let result = try decompile(script)
    #expect(try result.source == TestData.text("jxa/hello.js"))
    #expect(result.language == .javaScript)
    #expect(result.language.rawValue == "JavaScript")
    #expect(result.diagnostics.isEmpty)
    #expect(!result.embedded)

    // The options made for AppleScript change nothing.
    let options = DecompileOptions(strict: true, disableEmbeddedUnwrap: true, passes: [.strings])
    #expect(try decompile(script, options: options).source == result.source)

    #expect(try decompile(TestData.bytes("demo.scpt")).language == .appleScript)
}

@Test func `the library does not disassemble a JXA script`() throws {
    #expect {
        try disassemble(TestData.bytes("jxa/hello.scpt"))
    } throws: { error in
        error.localizedDescription == "a JavaScript for Automation (JXA) script holds source text, not bytecode: use 'decompile' to print it"
    }
}

@Test func `the size limit is for JXA scripts too`() throws {
    var options = DecompileOptions()
    options.limits.maxInputBytes = 64
    #expect {
        try decompile(TestData.bytes("jxa/hello.scpt"), options: options)
    } throws: { error in
        error.localizedDescription == "JXA stream exceeds 64-byte limit"
    }
}

/** A big-endian number as `count` bytes. */
private func bigEndian(_ value: Int, _ count: Int) -> [UInt8] {
    (0 ..< count).map { UInt8(truncatingIfNeeded: value >> (8 * (count - 1 - $0))) }
}

/**
 A binary property list made by hand: the objects, the table of their
 offsets, and the 32 bytes that end the list. A reference to an object
 and an offset are four bytes each.
 */
private func binaryPropertyList(_ objects: [[UInt8]]) -> [UInt8] {
    var out = Array("bplist00".utf8)
    var offsets: [Int] = []
    for object in objects {
        offsets.append(out.count)
        out += object
    }
    let table = out.count
    for offset in offsets {
        out += bigEndian(offset, 4)
    }
    return out + [0, 0, 0, 0, 0, 0, 4, 4] + bigEndian(objects.count, 8) + bigEndian(0, 8) + bigEndian(table, 8)
}

/**
 The property list of a JXA script is read by Foundation, and the file
 can come from anyone. These lists are made to break a reader:

 ```
 nested    100,000 arrays one inside the other, in the three forms
 shared    12 arrays, each with 255 times the next one: 255¹² values
           when each use of an object makes a new one
 cyclic    an array that holds itself
 long      a text that says it has 2⁶² bytes
 ```

 Foundation refuses each of them or reads it in no time, and the tool
 gives an error, as `Sources/FAS/JXA.swift` says. This test tells when
 a version of the system does otherwise.
 */
@Test func `a hostile property list in a JXA script`() {
    let depth = 100_000
    let nested = binaryPropertyList((0 ..< depth).map { [0xa1] + bigEndian($0 + 1, 4) } + [[0x51, 0x31]])
    let shared = binaryPropertyList((0 ..< 12).map { level in
        [0xaf, 0x10, 0xff] + (0 ..< 255).flatMap { _ in bigEndian(level + 1, 4) }
    } + [[0x51, 0x31]])
    let cyclic = binaryPropertyList([[0xa1] + bigEndian(1, 4), [0xa1] + bigEndian(0, 4)])
    let long = binaryPropertyList([[0xd1] + bigEndian(1, 4) + bigEndian(2, 4), [0x56] + Array("script".utf8), [0x5f, 0x13] + bigEndian(1 << 62, 8) + [0x31]])
    let xml = "<plist>" + String(repeating: "<array>", count: depth) + String(repeating: "</array>", count: depth) + "</plist>"
    let text = String(repeating: "(", count: depth) + String(repeating: ")", count: depth)

    let lists: [(String, [UInt8], String)] = [
        ("nested, binary", nested, "damaged property list"),
        ("nested, XML", Array(xml.utf8), "damaged property list"),
        ("nested, old text", Array(text.utf8), "damaged property list"),
        ("shared", shared, "not a dictionary"),
        ("cyclic", cyclic, "damaged property list"),
        ("long", long, "damaged property list"),
    ]
    for (name, list, want) in lists {
        let started = Date()
        #expect("\(name)") {
            try decompile(TestData.javaScript(propertyList: list))
        } throws: { error in
            error.localizedDescription.contains(want)
        }
        #expect(Date().timeIntervalSince(started) < 10, "\(name)")
    }
}
