import CryptoKit
import Foundation
import OSAToolbox
import Testing
import TestSupport

let compiledFixtureCount = 82

@Test func `demo decompiles`() throws {
    let result = try decompile(TestData.bytes("demo.scpt"))
    for want in ["on run", "collectEnvironmentInfo", "repeat", "end run"] {
        #expect(result.source.contains(want), "source missing \(want)")
    }
}

/**
 Every compiled fixture must decompile, in strict mode, to exactly its
 committed `.expected.applescript` file.
 */
@Test(arguments: TestData.compiledFixtures)
func `compiled oracle fixtures`(name: String) throws {
    var options = DecompileOptions(strict: true)
    if ["ascii_recovery", "naive_list_edges", "naive_empty_concat"].contains(name) {
        options.passes = [.strings]
    }
    let result = try decompile(TestData.bytes("compiled/\(name).scpt"), options: options)
    let expected = try TestData.text("compiled/\(name).expected.applescript")
    #expect(result.source == expected, "source differs from committed semantic golden")
}

/** Every pass the library names exists in the target of the passes. */
@Test func `every pass of the library exists`() throws {
    for pass in DecompilePass.allCases {
        #expect(try pass.pass().name == pass.rawValue)
    }
}

@Test func `fixture layout`() throws {
    let oracle = try TestData.names(in: "oracle", suffix: ".applescript")
    let compiled = try TestData.names(in: "compiled", suffix: ".scpt")
    let expected = try TestData.names(in: "compiled", suffix: ".expected.applescript")
    #expect(oracle.count == compiledFixtureCount)
    #expect(compiled.count == compiledFixtureCount)
    #expect(expected.count == compiledFixtureCount)
    for name in oracle {
        #expect(compiled.contains(name), "\(name) has no compiled fixture")
        #expect(expected.contains(name), "\(name) has no expected source")
    }
    #expect(!FileManager.default.fileExists(atPath: TestData.url("refinements.applescript").path))
}

/**
 `styled-text.scpt` holds one text, stored as styled text: the MacRoman
 bytes of "café" and a style table. `osadecompile` prints the same.
 */
@Test func `styled text in a script`() throws {
    let data = try TestData.bytes("styled-text.scpt")
    #expect(try decompile(data, options: DecompileOptions(strict: true)).source == "on f()\n    return \"café\"\nend f\n")
    #expect(try disassemble(data).text().contains("; \"café\""))
}

/**
 `seccon.scpt` is a loader: its only content is another compiled script,
 stored as raw data. By default the inner script is decompiled.
 */
@Test func `seccon embedded payload`() throws {
    let data = try TestData.bytes("seccon.scpt")
    let digest = SHA256.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "c32c327cf28404739a7873dae1bc8dfecc1d342f5484bd16338cc82b5d81712d")

    let result = try decompile(data)
    #expect(result.embedded, "embedded payload was not detected")
    let fragments = [
        "use framework \"Foundation\"",
        "use scripting additions",
        "considering numeric strings",
        "with timeout of 10 seconds",
        "copy codex to claude",
        "character id cid",
        "U1F99C:64104",
        "U1F41C:56473",
        "Pennsylvania div alaska",
        "virginia's |length|()",
        "current application's NSString's stringWithString:t",
        "{space, tab, return, linefeed}",
        "U1F41D of tennessee",
        "on Iidabashi(candidate)",
        "on Roppongi(newyorkcity)",
        "on Otemachi(cid)",
        "on Kanda(nsPayload, NewJersey, U1F9E7, westchester)",
        "on Sugamo(nsPayload, NewJersey, U1F9E7)",
        "on Jimbocho(t)",
        "on trimNSString(ns)",
        "on splitNSString(ns, delim)",
        "on Shimbashi(washingtondc, colorado, idaho, kansas)",
        "on Ginza(t)",
        "on stripWhitespace(t)",
        "on split(t, delim)",
    ]
    for fragment in fragments {
        #expect(result.source.contains(fragment), "embedded source missing \(fragment)")
    }
    for unwanted in ["parent_var_", ": ,", "«unsupported"] {
        #expect(!result.source.contains(unwanted), "embedded source contains \(unwanted)")
    }

    let wrapped = try decompile(data, options: DecompileOptions(disableEmbeddedUnwrap: true))
    #expect(!wrapped.embedded)
    #expect(wrapped.source.contains("«data scpt"), "wrapped source did not retain embedded data")
}

// MARK: - Code that a file could hide

/**
 `loaded-parent.scpt` was compiled with `osacompile -x` from:

 ```
 property parent : load script POSIX file "…/library.scpt"

 on mainHandler()
     return secret(1)
 end mainHandler
 ```

 The value of a property is made when the source is compiled, so the
 whole library is in the file, in the parent slot of the script and
 nowhere else. Its two handlers were not shown at all. The source the
 tool prints compiles, with the library as a script object.
 */
@Test func `a parent loaded when the script was compiled is shown`() throws {
    let data = try TestData.bytes("loaded-parent.scpt")
    let result = try decompile(data, options: DecompileOptions(strict: true))
    #expect(result.source == """
    script scriptObject
        on secret(x)
            return x + 41
        end secret

        on other()
            return "in the library"
        end other
    end script

    property parent : scriptObject

    on mainHandler()
        return secret(1)
    end mainHandler

    """)
    let listing = try disassemble(data, options: DisassembleOptions(strict: true))
    #expect(listing.functions.map(\.name) == [#""mainHandler""#, #""secret""#, #""other""#])
    #expect(listing.functions.map(\.path) == ["", "root.parent.vector[4][2]", "root.parent.vector[4][3]"])
}

/**
 `renamed-handler.scpt` was compiled from a script with two handlers,
 `helper` and `main`; then, in the file, the name that `helper` has for
 itself was changed to `hexper`. Its entry in the table of the script is
 still named `helper`, and `main` still calls `helper()`.

 An entry whose name is not the name of its handler looks like
 `property h : helper`, another name for a handler defined elsewhere.
 Here nothing else defines it, and the handler was not shown at all. It
 is now printed under the name of its entry, the one calls use, and the
 other name is reported.
 */
@Test func `a handler stored under a name that is not its own is shown`() throws {
    let data = try TestData.bytes("renamed-handler.scpt")
    let result = try decompile(data)
    #expect(result.source == """
    on helper()
        return "the payload"
    end helper

    on main()
        return helper()
    end main

    """)
    #expect(result.diagnostics.map(\.message) == [#"the handler stored as "helper" names itself "hexper""#])
    #expect(try disassemble(data).functions.count == 2)
}

/**
 A loader holds another compiled script as data, which can be a loader
 too. Each one is opened, up to a limit: a file made of thousands of
 loaders, each around the next, would be read thousands of times.
 */
@Test func `scripts stored one inside the other are opened up to a limit`() throws {
    let inner = try TestData.bytes("compiled/unicode_string.scpt")
    // A long block of raw data as the root object: kind 18, reference 0, class 13, the size, `scpt`, the script.
    func loader(_ script: [UInt8]) -> [UInt8] {
        let size = UInt32(script.count + 4)
        let count = (0 ..< 4).map { UInt8(truncatingIfNeeded: size >> (24 - 8 * UInt32($0))) }
        return Array("FasdUAS 1.101.10".utf8) + [18, 0, 0, 0, 0, 13] + count + Array("scpt".utf8) + script
    }
    var wrapped = inner
    for _ in 0 ..< 8 {
        wrapped = loader(wrapped)
    }
    let result = try decompile(wrapped)
    #expect(result.embedded)
    #expect(try result.source == decompile(inner).source)
    #expect(throws: (any Error).self) { try decompile(loader(wrapped)) }
    // The scripts are not opened when that is turned off: a loader alone is not a script.
    #expect(throws: (any Error).self) { try decompile(loader(inner), options: DecompileOptions(disableEmbeddedUnwrap: true)) }
}

/**
 Code that is far longer than any real handler. The file is
 `renamed-handler.scpt` with the three bytes of code of its first
 handler replaced by a long block of bytes:

 ```
 PushLiteral 0, then Not 200,000 times        one operation inside the other
 PushLiteral 0, then (PushLiteral 0, &) …     a chain of 100,000 operations
 BeginTimeout 200,000 times                   one block inside the other
 ```

 A megabyte of each ended the program: the code that walks the tree
 calls itself for each level. Now the tree is cut at a depth, and the
 cut is reported.
 */
@Test func `very long code is cut, and does not end the program`() throws {
    let template = try TestData.bytes("renamed-handler.scpt")
    // The code of the handler: a byte string (kind 17), its reference, its size 3, three bytes.
    let old: [UInt8] = [0x11, 0xff, 0xf6, 0x00, 0x03, 0xe0, 0x0f, 0x0f]
    let place = try #require(template.indices.first { template[$0...].starts(with: old) })
    func script(_ code: [UInt8]) -> [UInt8] {
        // A long byte string (kind 19): its reference, then its size in four bytes.
        let size = (0 ..< 4).map { UInt8(truncatingIfNeeded: code.count >> (24 - 8 * $0)) }
        return Array(template[..<place]) + [0x13, 0xff, 0xf6, 0x00, 0x00] + size + code + Array(template[(place + old.count)...])
    }
    let deep = try decompile(script([0xe0] + [UInt8](repeating: 0x0b, count: 200_000) + [0x0f]))
    #expect(deep.source.contains("«expression too deep»"))
    #expect(deep.diagnostics.contains { $0.message.contains("nested deeper than 50000 levels") })

    let chain = try decompile(script([0xe0] + [[UInt8]](repeating: [0xe0, 0x25], count: 100_000).joined() + [0x0f]))
    #expect(chain.diagnostics.contains { $0.message.contains("nested deeper than 50000 levels") })

    let blocks = try decompile(script([UInt8](repeating: 0x6e, count: 200_000) + [0x0f]))
    #expect(blocks.source.contains("on main()"))
    #expect(blocks.diagnostics.contains { $0.message.contains("blocks are nested deeper than 1024 levels") })

    // A chain under the limit is printed whole.
    let short = try decompile(script([0xe0] + [[UInt8]](repeating: [0xe0, 0x25], count: 1000).joined() + [0x0f]))
    #expect(short.source.components(separatedBy: #""the payload""#).count == 1002)
}
