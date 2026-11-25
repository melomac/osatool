import Extensions
import OSAToolbox
import Terminology
import Testing
import TestSupport

@Test func `demo disassembly`() throws {
    let listing = try disassemble(TestData.bytes("demo.scpt"), options: DisassembleOptions(strict: true))
    #expect(!listing.functions.isEmpty, "no functions")
    let text = listing.text()
    #expect(!text.contains(" owner=") && !text.contains(" path="), "ordinary root disassembly gained nested ownership metadata")
    let mnemonics = [
        "PushLiteral", "PushGlobal", "PopGlobal", "PushVariable", "PopVariable",
        "PushParentVariable", "PositionalMessageSend", "MessageSend",
        "MakeObjectAlias", "StoreResult", "LinkRepeat", "TestIf", "Jump", "Return",
        "ErrorHandler", "RepeatInRange",
    ]
    for want in mnemonics {
        #expect(text.contains(want), "disassembly missing \(want)")
    }
    let expectedNames = [
        5: "collectEnvironmentInfo",
        6: "deobfuscateStringList",
        7: "demoRepeats",
        14: "escapeQuotes",
    ]
    for (offset, name) in expectedNames {
        let found = listing.functions.contains { $0.offset == offset && $0.name.contains(name) }
        #expect(found, "function[\(offset)] \(name) missing from stable demo shape")
    }
}

@Test func `nested function ownership text`() {
    let listing = Disassembly(version: "1.10", functions: [
        DisassemblyFunction(offset: 8, name: "\"clicked_\"", arguments: "nil", owner: "\"AppDelegate\"", path: "root[2].vector[4][8]"),
    ])
    let text = listing.text()
    for want in ["owner=\"AppDelegate\"", "path=root[2].vector[4][8]"] {
        #expect(text.contains(want), "nested disassembly missing \(want)")
    }
}

/**
 The JSON form of the diagnostics is part of schema version 1: the
 severity is always 1, a position that is not known is written as -1,
 and a position that is 0 is left out.
 */
@Test func `diagnostics in the JSON listing`() {
    let listing = Disassembly(version: "1.10", diagnostics: [
        Diagnostic(stage: .parse, offset: 161, message: "RefID mismatch: expected 2, found 7"),
        Diagnostic(stage: .decode, function: 2, offset: 0, opcode: 97, message: "truncated operand"),
    ])
    let want = """
      "diagnostics": [
        {
          "severity": 1,
          "stage": "parse",
          "offset": 161,
          "function": -1,
          "message": "RefID mismatch: expected 2, found 7"
        },
        {
          "severity": 1,
          "stage": "decode",
          "function": 2,
          "opcode": 97,
          "message": "truncated operand"
        }
      ]
    """
    #expect(listing.json().contains(want), "\(listing.json())")
}

/**
 A text literal is a vector of class 177 around its UTF-16 text: the
 listing shows the text, not the vector.
 */
@Test func `text literals in the listing`() throws {
    let text = try disassemble(TestData.bytes("demo.scpt")).text()
    #expect(text.contains("literal-index=6  ; \"Starting demo script…\"\n"))
    #expect(!text.contains("vector(type=177"))
}

/** The comments give what the bytes do not show: names, words, forms. */
@Test func `comments in the listing`() throws {
    let text = try disassemble(TestData.bytes("demo.scpt")).text()
    let wanted = [
        "MakeObjectAlias           ; index\n",
        "RepeatInRange           variable-index=3  ; \"i\"\n",
        "PushParentVariable      parent-depth=1, variable-index=0  ; \"current_prefix\"\n",
        "; constant(0x636f626a) 'cobj' item\n",
        "; constant(0x54455854) 'TEXT' string\n",
        "0xffff8000,\"TEXT\",0x00000000) do shell script\n",
    ]
    for want in wanted {
        #expect(text.contains(want), "listing missing \(want)")
    }
}

/** Without a dictionary a code keeps its characters and gets no word. */
@Test func `comments without terminology`() throws {
    let options = DisassembleOptions(terminology: ScriptingTerminology(Registry()))
    let text = try disassemble(TestData.bytes("demo.scpt"), options: options).text()
    #expect(text.contains("; constant(0x636f626a) 'cobj'\n"))
    #expect(text.contains("0xffff8000,\"TEXT\",0x00000000)\n"))
    #expect(text.contains("MakeObjectAlias           ; index\n"))
}
