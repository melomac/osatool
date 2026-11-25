import Extensions
import Foundation
@testable import Terminology
import Testing

let fixture = """
<?xml version="1.0"?>
<dictionary><suite name="Port Suite" code="PORT">
  <command name="perform task" code="PORTtask">
    <direct-parameter type="text"/>
    <parameter name="quietly" code="quie" type="boolean"/>
    <parameter name="destination" code="dest" type="text"/>
    <parameter name="ignored without code"/>
  </command>
  <enumeration name="mode" code="mode"><enumerator name="fast mode" code="fast"/></enumeration>
  <class name="document" code="docu"><property name="title" code="ptit"/></class>
</suite></dictionary>
"""

@Test func `parse SDEF`() throws {
    let d = try parseSDEF(name: "Port", data: Data(fixture.utf8))
    let event = try EventCode(parsing: "PORTtask")
    let command = d.commands[event] ?? Command()
    try #require(command.name == "perform task" && command.hasDirectParameter, "command = \(command)")
    let quietly = try Code4(parsing: "quie")
    try #require(
        command.parameters[quietly]?.name == "quietly" && command.parameters[quietly]?.type == "boolean",
        "parameter = \(String(describing: command.parameters[quietly]))",
    )
    let destination = try Code4(parsing: "dest")
    try #require(
        command.parameters[destination]?.name == "destination" && command.parameters[destination]?.type == "text",
        "parameter = \(String(describing: command.parameters[destination]))",
    )
    try #require(
        command.parameters.count == 2,
        "parameters = \(command.parameters); parameter without code was not ignored",
    )
    let fast = try Code4(parsing: "fast")
    try #require(d.enums[fast] == "fast mode", "enum = \(d.enums)")
    let modeFast = try EventCode(parsing: "modefast")
    try #require(d.constants[modeFast] == "fast mode", "grouped enum = \(d.constants)")
}

@Test func `bundled registry`() throws {
    let r = try Registry.default()
    try #require(r.dictionary("Finder") != nil, "Finder dictionary missing")
    try #require(r.dictionary("Standard Additions") != nil, "Standard Additions alias missing")
    let errn = try Code4(parsing: "errn")
    let got = r.parameter(errn)
    try #require(got == "number", "errn parameter = \(String(describing: got))")
}

@Test func `generated language terminology`() throws {
    let registry = try Registry.default()
    let cases: [(text: String, want: String)] = [
        ("txdl", "text item delimiters"),
        ("ascr", "AppleScript"),
        ("ldt ", "date"),
        ("citm", "text item"),
        ("obj ", "reference"),
        ("rvse", "reverse"),
        ("utxt", "Unicode text"),
        ("wkdy", "weekday"),
        ("ID  ", "id"),
        ("spac", "space"),
    ]
    for (text, want) in cases {
        let code = try Code4(parsing: text)
        let got = registry.languageTerm(code)
        #expect(got == want, "LanguageTerm(\(text)) = \(String(describing: got)); want \(want)")
    }
    let caseCode = try Code4(parsing: "case")
    let enumeration = registry.languageEnumeration(caseCode)
    #expect(enumeration == "case", "LanguageEnumeration(case) = \(String(describing: enumeration))")
    let consideringCase = try EventCode(parsing: "conscase")
    let constant = registry.constant(consideringCase)
    #expect(constant == "case", "Constant(conscase) = \(String(describing: constant))")
    let expansion = try Code4(parsing: "expa")
    #expect(registry.languageTerm(expansion) == nil, "framework terminology unexpectedly contains expa term")
    #expect(
        registry.languageEnumeration(expansion) == nil,
        "framework terminology unexpectedly contains expa enumeration",
    )
}

@Test func `language builtin commands`() throws {
    let registry = try Registry.default()
    let cases: [(codeText: String, want: String)] = [
        ("ascrnoop", "launch"),
        ("coredelo", "delete"),
        ("coredoex", "exists"),
        ("CoRedelo", "delete"),
        ("CoRedoex", "exists"),
    ]
    for (codeText, want) in cases {
        let code = try EventCode(parsing: codeText)
        let got = registry.command(code)
        #expect(got?.name == want, "Command(\(codeText)) = \(String(describing: got)); want \(want)")
    }
}

@Test func `application terms are not overwritten by language terminology`() throws {
    let registry = try Registry.default()
    // A word of an application is known inside a `tell` block for it.
    #expect(registry.term("rtyp") == nil)
    #expect(registry.scoped(to: "Mail").term("rtyp") == "rule type")
    #expect(registry.scoped(to: "System Events").term("asup") == "application support folder")
    #expect(registry.term("ID  ") == "id")
    let id = try Code4(parsing: "ID  ")
    // One application may give the code its own name. That name stays in
    // the dictionary of this application only.
    #expect(registry.dictionary("Calendar")?.terms[id] == "calendarIdentifier")
    let languageID = registry.languageTerm(id)
    #expect(languageID == "id", "language ID = \(String(describing: languageID)); want id")
    let rtyp = try Code4(parsing: "rtyp")
    let parameter = registry.parameter(rtyp)
    #expect(parameter == "as", "language rtyp parameter = \(String(describing: parameter)); want as")
}

@Test func `contextual command parameters`() throws {
    let registry = try Registry.default()
    let kocl = try Code4(parsing: "kocl")
    let cases: [(codeText: String, want: String)] = [
        ("corecrel", "new"),
        ("corecnte", "each"),
    ]
    for (codeText, want) in cases {
        let event = try EventCode(parsing: codeText)
        let command = try #require(registry.command(event), "command \(codeText) missing")
        let got = command.parameters[kocl]?.name ?? ""
        #expect(got == want, "\(command.name) kocl = \(got), want \(want)")
    }
    let got = registry.parameter(kocl)
    #expect(got == nil, "ambiguous kocl received context-free name \(String(describing: got))")
}

@Test func `grouped enumerations remain distinct`() throws {
    let registry = try Registry.default()
    let cases: [(codeText: String, want: String)] = [
        ("afdrasup", "application support"),
        ("afdmasup", "application support folder"),
    ]
    for (codeText, want) in cases {
        let code = try EventCode(parsing: codeText)
        let got = registry.constant(code)
        #expect(got == want, "Constant(\(codeText)) = \(String(describing: got)); want \(want)")
    }
}

@Test func `sdef enumerations terms and direct parameters`() throws {
    let source = """
    <dictionary><suite name="Events" code="evnt">
    \t  <command name="handler event" code="evnthndl"><direct-parameter type="list"/>
    \t    <parameter name="quietly" code="quie" type="boolean"/></command>
    \t  <command name="ordinary event" code="evntordn"/>
    \t  <enumeration name="mode" code="mode"><enumerator name="fast mode" code="fast"/></enumeration>
    \t  <class name="document" code="docu"><property name="title" code="ptit"/></class>
    \t  <type name="custom type" code="cust"/>
    \t</suite></dictionary>
    """
    let dictionary = try parseSDEF(name: "Events", data: Data(source.utf8))
    let handlerCode = try EventCode(parsing: "evnthndl")
    let ordinaryCode = try EventCode(parsing: "evntordn")
    try #require(
        dictionary.commands[handlerCode]?.hasDirectParameter ?? false,
        "direct parameter was not recorded",
    )
    try #require(
        !(dictionary.commands[ordinaryCode]?.hasDirectParameter ?? false),
        "ordinary command gained a direct parameter",
    )
    let cases: [(codeText: String, want: String)] = [
        ("fast", "fast mode"),
        ("docu", "document"),
        ("ptit", "title"),
        ("cust", "custom type"),
    ]
    for (codeText, want) in cases {
        let code = try Code4(parsing: codeText)
        var got = dictionary.terms[code] ?? ""
        if let enumeration = dictionary.enums[code], !enumeration.isEmpty {
            got = enumeration
        }
        #expect(got == want, "\(codeText) = \(got), want \(want)")
    }
}

/** The kinds of type, a second code for a word, and the files a definition includes. */
@Test func `sdef types, synonyms and included files`() throws {
    let source = """
    <dictionary xmlns:xi="http://www.w3.org/2003/XInclude">
      <xi:include href="file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef" xpointer="xpointer(/dictionary/suite)"/>
      <suite name="S" code="SSSS">
        <xi:include href="Shared.sdef"/>
        <xi:include/>
        <record-type name="dialog reply" code="askr"><property name="button returned" code="bhit"/></record-type>
        <value-type name="specifier" code="obj "/>
        <class name="folder" code="cfol">
          <property name="desktop pictures folder" code="dtp$"><synonym code="dtpQ"/><synonym name="desktop pictures"/></property>
        </class>
      </suite>
    </dictionary>
    """
    let (dictionary, includes) = try parseSDEFDocument(name: "S", data: Data(source.utf8))
    #expect(includes == ["file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef", "Shared.sdef"])
    #expect(dictionary.terms["askr"] == "dialog reply" && dictionary.terms["bhit"] == "button returned")
    #expect(dictionary.terms["obj "] == "specifier")
    #expect(dictionary.terms["dtp$"] == "desktop pictures folder" && dictionary.terms["dtpQ"] == "desktop pictures folder")
    #expect(dictionary.terms.count == 6)
    // The simple form reads the same words.
    #expect(try parseSDEF(name: "S", data: Data(source.utf8)).terms == dictionary.terms)
}

@Test func `mac roman four character code`() throws {
    let code = try Code4(parsing: "scrƒ")
    try #require(code == Code4(bytes: [UInt8(ascii: "s"), UInt8(ascii: "c"), UInt8(ascii: "r"), 0xc4]), "code = \(code)")
}

@Test func `mac roman four character code uses complete repertoire`() throws {
    let code = try Code4(parsing: "café")
    try #require(code == Code4(bytes: [UInt8(ascii: "c"), UInt8(ascii: "a"), UInt8(ascii: "f"), 0x8e]), "code = \(code)")
}

/** A class has a plural name: its own, or its name with an "s". The language has its own list. */
@Test func `plural names of classes`() throws {
    let dictionary = try parseSDEF(name: "test", data: Data((
        #"<dictionary><suite name="test" code="test">"#
            + #"<class name="box" code="tbox" plural="boxes"/><class name="window" code="twin"/>"#
            + #"<property name="size" code="tsiz"/></suite></dictionary>"#
    ).utf8))
    #expect(dictionary.plurals["tbox"] == "boxes")
    #expect(dictionary.plurals["twin"] == "windows")
    #expect(dictionary.plurals["tsiz"] == nil)

    let terms = try Registry.default()
    #expect(terms.plural("cobj") == "items")
    #expect(terms.plural("cha ") == "characters")
    // The plural of `text` is `text`: an application cannot change that.
    #expect(terms.plural("ctxt") == "text")
    #expect(terms.plural("zzzz") == nil)
}

/**
 The name of some classes is also their plural: the compiler reads
 `text of x` as `every text of x`. `osacompile` gives the same code for
 the two forms with these classes, and not with `Unicode text`.
 */
@Test func `classes that are their own plural`() throws {
    let registry = try Registry.default()
    #expect(registry.isOwnPlural("ctxt") && registry.isOwnPlural("STXT") && registry.isOwnPlural("itxt"))
    // A range is written `Unicode text 1 thru 2`, but the word alone is a property.
    #expect(registry.plural("utxt") == "Unicode text" && !registry.isOwnPlural("utxt"))
    #expect(!registry.isOwnPlural("cobj") && !registry.isOwnPlural("zzzz"))
    // TextEdit has the word of the language. Mail has its own word, with itself as the plural.
    #expect(registry.scoped(to: "TextEdit").isOwnPlural("ctxt"))
    let mail = registry.scoped(to: "Mail")
    #expect(mail.term("ctxt") == "rich text" && mail.isOwnPlural("ctxt"))
    #expect(mail.term("mssg") == "message" && !mail.isOwnPlural("mssg"))
}

/** The plurals are saved with a dictionary and read back. */
@Test func `store keeps plural names`() throws {
    var store = TerminologyStore()
    store.replace(with: [ScriptingDictionary(name: "test", terms: ["tbox": "box"], plurals: ["tbox": "boxes"])])
    let again = try TerminologyStore(data: store.data())
    #expect(again.dictionaries.first?.plurals["tbox"] == "boxes")
}

/**
 Inside `tell application "X"`, the words of X come first. Two
 applications can give two words to one code.
 */
@Test func `the words of the told application come first`() {
    var registry = Registry()
    let duplicate: EventCode = "coreclon"
    registry.add(ScriptingDictionary(
        name: "Finder", commands: [duplicate: Command(code: duplicate, name: "duplicate")],
        terms: ["home": "home", "cfol": "folder"], plurals: ["cfol": "folders"],
    ))
    var withParameter = Command(code: duplicate, name: "copy it")
    withParameter.parameters["alrp"] = CommandParameter(code: "alrp", name: "replacing", type: "boolean")
    withParameter.parameterOrder = ["alrp"]
    registry.add(ScriptingDictionary(
        name: "System Events", commands: [duplicate: withParameter],
        terms: ["home": "home directory", "cfol": "directory"], enums: ["yes ": "yes"],
    ))
    // Outside a `tell` block no application gives a word.
    #expect(registry.term("home") == nil)
    #expect(registry.command(duplicate) == nil)

    let events = registry.scoped(to: "System Events")
    #expect(events.term("home") == "home directory")
    #expect(events.command(duplicate)?.name == "copy it")
    // The plural of another word for the code is not kept.
    #expect(events.term("cfol") == "directory")
    #expect(events.plural("cfol") == nil)

    #expect(registry.scoped(to: "Finder").term("home") == "home")
    #expect(registry.scoped(to: "/System/Library/CoreServices/Finder.app").plural("cfol") == "folders")
    #expect(registry.scoped(to: "finder").term("cfol") == "folder")
    // An application that is not known changes nothing.
    #expect(registry.scoped(to: "Unknown").term("home") == nil)
}

/**
 The compiler knows the words of an application only inside a `tell`
 block for it. The words of a scripting addition are known everywhere.
 */
@Test func `the words of an application are known only inside its tell block`() {
    var registry = Registry()
    registry.add(ScriptingDictionary(
        name: "StandardAdditions", commands: ["sysobeep": Command(code: "sysobeep", name: "beep")], terms: ["home": "home directory"],
    ))
    registry.add(ScriptingDictionary(
        name: "Tools", sources: ["/Library/ScriptingAdditions/Tools.osax/Contents/Resources/Tools.sdef"], terms: ["tool": "tool"],
    ))
    var finder = ScriptingDictionary(
        name: "Finder", sources: ["/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.sdef"],
        commands: ["fndrfupd": Command(code: "fndrfupd", name: "update")],
        terms: ["home": "home", "brow": "Finder window"], enums: ["icnv": "icon view"], constants: ["ecvwicnv": "icon view"],
        plurals: ["brow": "Finder windows"],
    )
    finder.bundleID = "com.apple.finder"
    registry.add(finder)
    registry.add(ScriptingDictionary(name: "System Events", terms: ["prcs": "process"]))

    // Outside a `tell` block.
    #expect(registry.term("home") == "home directory")
    #expect(registry.term("tool") == "tool")
    #expect(registry.term("brow") == nil && registry.plural("brow") == nil)
    #expect(registry.enumeration("icnv") == nil && registry.constant("ecvwicnv") == nil)
    #expect(registry.command("fndrfupd") == nil)
    #expect(registry.command("sysobeep")?.name == "beep")
    #expect(!registry.isScriptWord("update"))
    // A text that is not source can still name the command.
    #expect(registry.commandAnywhere("fndrfupd")?.name == "update")
    #expect(registry.commandAnywhere("sysobeep")?.name == "beep")
    #expect(registry.commandAnywhere("zzzzzzzz") == nil)

    // Inside `tell application "Finder"`: by name, by path, by identifier.
    let byName = registry.scoped(to: "Finder")
    let byPath = registry.scoped(to: "/System/Library/CoreServices/Finder.app")
    let byIdentifier = registry.scoped(toID: "COM.apple.Finder")
    for inside in [byName, byPath, byIdentifier] {
        #expect(inside.term("home") == "home" && inside.term("brow") == "Finder window")
        #expect(inside.plural("brow") == "Finder windows")
        #expect(inside.enumeration("icnv") == "icon view" && inside.constant("ecvwicnv") == "icon view")
        #expect(inside.command("fndrfupd")?.name == "update")
        #expect(inside.isScriptWord("update"))
        // The language and scripting additions are known there too.
        #expect(inside.term("tool") == "tool" && inside.command("sysobeep")?.name == "beep")
        // The words of another application are not.
        #expect(inside.term("prcs") == nil)
    }
    // An unknown application, and a scripting addition, change nothing.
    #expect(registry.scoped(to: "Unknown").term("brow") == nil)
    #expect(registry.scoped(toID: "com.example.unknown").term("brow") == nil)
    #expect(registry.scoped(toID: "").term("prcs") == nil)
    #expect(registry.scoped(to: "Tools").term("brow") == nil)
}

/**
 An application with script suites and no `.sdef` file also has the
 words of the suites that Cocoa adds. An application with an `.sdef`
 file names its words in that file, and the system adds those of
 `Intrinsics.sdef`.
 */
@Test func `an application with script suites has the suites of Cocoa`() {
    var registry = Registry()
    registry.add(ScriptingDictionary(
        name: "Foundation", sources: ["/F/Foundation.framework/Resources/NSCoreSuite.scriptSuite"],
        commands: ["corecrel": Command(code: "corecrel", name: "make")], terms: ["docu": "document", "ptit": "titled"],
    ))
    registry.add(ScriptingDictionary(name: "AppKit", sources: ["/F/AppKit.framework/Resources/NSTextSuite.scriptSuite"], terms: ["cpar": "paragraph"]))
    registry.add(ScriptingDictionary(name: "CocoaStandard", sources: ["/S/CocoaStandard.sdef"], terms: ["pset": "print settings", "docu": "other document"]))
    registry.add(ScriptingDictionary(name: "Intrinsics", sources: ["/F/Foundation.framework/Resources/Intrinsics.sdef"], terms: ["obj ": "specifier"]))
    registry.add(ScriptingDictionary(
        name: "TextEdit", sources: ["/A/TextEdit.app/Contents/Resources/TextEdit.scriptSuite", "/A/TextEdit.app/Contents/Resources/TextEdit.scriptTerminology"],
        terms: ["ptit": "title"],
    ))
    registry.add(ScriptingDictionary(name: "Safari", sources: ["/A/Safari.app/Contents/Resources/Safari.sdef"], terms: ["bTab": "tab"]))

    let textEdit = registry.scoped(to: "TextEdit")
    #expect(textEdit.term("docu") == "document" && textEdit.term("cpar") == "paragraph")
    #expect(textEdit.command("corecrel")?.name == "make")
    // Its own word comes first, then the suites in their order.
    #expect(textEdit.term("ptit") == "title")
    #expect(textEdit.term("pset") == "print settings")
    // The types of `Intrinsics.sdef` are for an application with an `.sdef` file.
    #expect(textEdit.term("obj ") == nil)

    let safari = registry.scoped(to: "Safari")
    #expect(safari.term("bTab") == "tab" && safari.term("obj ") == "specifier")
    #expect(safari.term("docu") == nil && safari.term("pset") == nil && safari.command("corecrel") == nil)
    #expect(registry.term("docu") == nil && registry.term("obj ") == nil)
    // An application that no dictionary describes.
    #expect(registry.scoped(to: "Unknown").term("obj ") == "specifier" && registry.scoped(to: "Unknown").term("docu") == nil)
}

/**
 `use application` makes the words of an application known in the whole
 script. `folder` is a word of Finder and of System Events, and not of
 the language: with both applications, the compiler refuses it.
 */
@Test func `the words of used applications`() throws {
    let registry = try Registry.default()
    #expect(registry.using([]).term("brow") == nil)
    #expect(registry.using([.name("Unknown"), .identifier("")]).term("brow") == nil)

    let finder = registry.using([.identifier("com.apple.finder")])
    #expect(finder.term("brow") == "Finder window" && finder.term("cfol") == "folder" && finder.term("home") == "home")
    #expect(finder.command("fndrfupd")?.name == "update")
    // A `tell` block for another application puts the words of that one first.
    #expect(finder.scoped(to: "System Events").term("home") == "home directory")
    #expect(finder.scoped(to: "System Events").term("brow") == "Finder window")

    let both = registry.using([.name("Finder"), .name("System Events")])
    #expect(both.term("brow") == "Finder window" && both.term("uiel") == "UI element")
    // The first line comes first.
    #expect(both.term("home") == "home")
    #expect(registry.using([.name("System Events"), .name("Finder")]).term("home") == "home directory")
    // A word of both is not known; a word of the language is.
    #expect(both.term("cfol") == nil && both.plural("cfol") == nil && both.term("cdis") == nil)
    #expect(both.term("cwin") == "window" && both.term("pnam") == "name")
    #expect(both.scoped(to: "Finder").term("cfol") == "folder")
    // The same application named twice is one application.
    #expect(registry.using([.name("Finder"), .identifier("com.apple.finder")]).term("cfol") == "folder")
}

/**
 The system adds a few words to every application. `properties` is one:
 inside a `tell` block for an application it is a property, and outside
 the compiler reads it as `every property`.
 */
@Test func `every application has the words the system adds`() throws {
    let registry = try Registry.default()
    #expect(registry.term("pALL") == nil)
    for inside in [registry.scoped(to: "Safari"), registry.scoped(to: "Finder"), registry.scoped(to: "TextEdit")] {
        #expect(inside.term("pALL") == "properties" && inside.term("pcls") == "class" && inside.term("cobj") == "item")
    }
    // Also an application that no dictionary describes.
    #expect(registry.scoped(to: "Unknown").term("pALL") == "properties")
    #expect(registry.scoped(toID: "com.example.unknown").term("pALL") == "properties")
    #expect(registry.scoped(to: "Unknown").term("brow") == nil)
    // Its own word for a code comes first.
    #expect(registry.scoped(to: "Finder").term("cobj") == "item")
    #expect(registry.dictionary(intrinsicsDictionaryName)?.sources.count == 1)
}

/**
 The language table has only the words the compiler gives back
 (`Scripts/compiler-words.py`). The terminology of the system also
 lists words of old suites, which the compiler refuses or reads as the
 name of a variable.
 */
@Test func `the language has no word the compiler does not give back`() throws {
    let registry = try Registry.default()
    // Refused, a variable, another code, a plural of another class.
    for code: Code4 in ["cadb", "crow", "ccel", "ctbl", "cltb", "prop", "pALL", "c@#^", "undf"] {
        #expect(registry.term(code) == nil, "\(code)")
    }
    for code: Code4 in ["eadb", "ecus", "arbo", "indx", "nmod", "cpy "] {
        #expect(registry.enumeration(code) == nil, "\(code)")
    }
    // A word of Standard Additions that a word of the language hides.
    #expect(registry.term("pURL") == nil)
    // Kept: a class, a property of `it`, a global property, a type, enumerators.
    #expect(registry.term("ctxt") == "text" && registry.term("pnam") == "name" && registry.term("pi  ") == "pi")
    #expect(registry.term("STXT") == "styled text" && registry.term("cwin") == "window")
    #expect(registry.enumeration("yes ") == "yes" && registry.constant("boovtrue") == "true" && registry.constant("boovfals") == "false")
    #expect(registry.constant("conscase") == "case" && registry.constant("afdrtrsh") == "trash")
}

/** A dictionary added twice keeps what it had, and gets what is new. */
@Test func `a dictionary added again keeps its first words`() {
    var registry = Registry()
    registry.add(ScriptingDictionary(name: "Thing", terms: ["aaaa": "first"]))
    var again = ScriptingDictionary(name: "Thing", terms: ["aaaa": "second", "bbbb": "more"])
    again.bundleID = "com.example.thing"
    registry.add(again)
    let thing = registry.scoped(toID: "com.example.thing")
    #expect(thing.term("aaaa") == "first" && thing.term("bbbb") == "more")
}

/**
 The words that need bars come from the compiler, in the language
 table. The words of the language come before those of an application.
 */
@Test func `the default registry knows the reserved words and the language first`() throws {
    let registry = try Registry.default()
    for word in ["count", "name", "it", "error", "Size", "left", "null"] {
        #expect(registry.isScriptWord(word), "\(word)")
    }
    // The endings of `1st`, `2nd`, `3rd`, `4th`, the first word of `relative to`, the second word of `set volume`.
    for word in ["st", "nd", "rd", "th", "relative", "volume"] {
        #expect(registry.isScriptWord(word), "\(word)")
    }
    for word in ["total", "row", "cell", "finder", "counter", "x"] {
        #expect(!registry.isScriptWord(word), "\(word)")
    }
    #expect(registry.term("obj ") == "reference")
    #expect(registry.term("capp") == "application")
    #expect(registry.term("cmtr") == "centimeters")
    #expect(registry.scoped(to: "Finder").term("home") == "home")
    #expect(registry.scoped(to: "System Events").term("home") == "home directory")
    // A word of Finder only, by the name and by the identifier of Finder.
    #expect(registry.term("brow") == nil)
    #expect(registry.scoped(to: "Finder").term("brow") == "Finder window")
    #expect(registry.scoped(toID: "com.apple.finder").term("brow") == "Finder window")
    // Safari takes the standard suite from another file.
    #expect(registry.scoped(to: "Safari").term("docu") == "document")
    #expect(registry.scoped(to: "Safari").term("obj ") == "specifier")
    // TextEdit has script suites only: Cocoa adds its standard suite, its
    // text suite and the types for printing. `osadecompile` prints these
    // words inside `tell application "TextEdit"`.
    let textEdit = registry.scoped(to: "TextEdit")
    #expect(textEdit.term("cpar") == "paragraph" && textEdit.term("catr") == "attribute run")
    #expect(textEdit.plural("catr") == "attribute runs")
    #expect(textEdit.term("ppth") == "path" && textEdit.term("pset") == "print settings" && textEdit.term("lwcp") == "copies")
    #expect(textEdit.term("obj ") == "reference")
    #expect(registry.term("catr") == nil && registry.term("pset") == nil)
    // A record type of Standard Additions.
    #expect(registry.term("askr") == "dialog reply")
}

/**
 A handler can answer a command of an application. The dictionary that
 has the command gives the application; a framework is not one.
 */
@Test func `the application that has a command`() throws {
    var registry = Registry()
    let rule: EventCode = "emalcpma"
    let shared: EventCode = "coreclos"
    registry.add(ScriptingDictionary(
        name: "CocoaStandard", sources: ["/System/Library/ScriptingDefinitions/CocoaStandard.sdef"],
        commands: [shared: Command(code: shared, name: "close")],
    ))
    registry.add(ScriptingDictionary(
        name: "Mail", sources: ["/System/Applications/Mail.app/Contents/Resources/Mail.sdef"],
        commands: [rule: Command(code: rule, name: "perform mail action with messages"), shared: Command(code: shared, name: "close")],
        terms: ["subj": "subject", "mssg": "message"], plurals: ["mssg": "messages"],
    ))
    #expect(registry.application(of: rule) == "Mail")
    #expect(registry.application(of: shared) == "Mail")
    #expect(registry.application(of: "zzzzyyyy") == nil)

    // Inside `tell application "Mail"`, its words need bars as names.
    #expect(!registry.isScriptWord("subject"))
    let mail = registry.scoped(to: "Mail")
    #expect(mail.isScriptWord("subject") && mail.isScriptWord("Messages") && mail.isScriptWord("close"))
    #expect(!mail.isScriptWord("total"))

    // A command of the language or of Standard Additions needs no application.
    #expect(try Registry.default().application(of: "sysodlog") == nil)
    #expect(try Registry.default().application(of: rule) == "Mail")
    #expect(try Registry.default().scoped(to: "Terminal").term("tcnt") == "selected tab")
}

// MARK: - What is learned never takes the place of what is built in

/** A dictionary that gives its own words to two codes of the language and of Standard Additions, and to two new codes. */
private func renaming(_ name: String, identifier: String = "") throws -> ScriptingDictionary {
    let source = """
    <dictionary><suite name="s" code="evil">
    <command name="reveal harmless" code="sysoexec"><direct-parameter type="text"/></command>
    <command name="count sheep" code="evilevil"/>
    <class name="money" code="ctxt"/>
    <class name="sheep" code="shee"/>
    <enumeration name="e" code="savo"><enumerator name="maybe" code="yes "/><enumerator name="often" code="oftn"/></enumeration>
    </suite></dictionary>
    """
    var dictionary = try parseSDEF(name: name, data: Data(source.utf8))
    dictionary.bundleID = identifier
    return dictionary
}

/**
 A file that `learn` reads can be made by anyone, and it can have the
 name of a well-known application. Inside a `tell` block the words of
 the application come first, so such a file renamed a command of
 Standard Additions there:

 ```
 tell application "Finder" to do shell script "…"
 tell application "Finder" to reveal harmless "…"       with a learned Finder.app
 ```

 A dictionary added under a name that is there already gives words only
 to the codes that had none.
 */
@Test func `a learned dictionary does not rename what is built in`() throws {
    let shell = try EventCode(parsing: "sysoexec")
    let sheep = try EventCode(parsing: "evilevil")
    let scopes: [(String, ApplicationName)] = [
        // The name of a built-in application, also in another letter case.
        ("Finder", .name("Finder")), ("finder", .name("Finder")), ("FINDER", .name("finder")),
        // What the system adds to every application, and to the ones with script suites.
        ("Intrinsics", .name("Finder")), ("Intrinsics", .name("Nobody")), ("AppKit", .name("TextEdit")), ("CocoaStandard", .name("TextEdit")),
    ]
    for (name, scope) in scopes {
        var registry = try Registry.default()
        let before = registry.scoped(to: scope)
        try registry.add(renaming(name))
        let after = registry.scoped(to: scope)
        #expect(after.commands[shell]?.name == "do shell script", "\(name)")
        #expect(after.terms["ctxt"] == before.terms["ctxt"] && after.enums["yes "] == "yes", "\(name)")
        #expect(try after.constants == before.constants.merging([EventCode(parsing: "savooftn"): "often"]) { first, _ in first }, "\(name)")
        // A code that had no word gets one.
        #expect(after.commands[sheep]?.name == "count sheep" && after.terms["shee"] == "sheep" && after.enums["oftn"] == "often", "\(name)")
        // No second dictionary was made for the other letter case.
        #expect(try registry.dictionaries.count == (Registry.default().dictionaries.count), "\(name)")
    }
    // Under a new name the words are those of the application, inside its `tell` blocks only.
    var registry = try Registry.default()
    try registry.add(renaming("Sheepdog"))
    #expect(registry.scoped(to: "Sheepdog").commands[shell]?.name == "reveal harmless")
    #expect(registry.scoped(to: "sheepDOG").terms["ctxt"] == "money")
    #expect(registry.commands[shell]?.name == "do shell script" && registry.scoped(to: "Finder").terms["shee"] == nil)
    // Added a second time, with other words: the first ones stay.
    var again = try renaming("sheepdog")
    again.terms["shee"] = "goat"
    again.terms["goat"] = "goat"
    registry.add(again)
    #expect(registry.scoped(to: "Sheepdog").terms["shee"] == "sheep" && registry.scoped(to: "Sheepdog").terms["goat"] == "goat")
}

/**
 `tell application id "com.apple.finder"` finds a dictionary by its
 identifier, and a file can claim any identifier. The first name in the
 alphabet won: a learned `Aaa.app` took the place of Finder. The first
 dictionary added wins now, and the built-in ones are added first.
 */
@Test func `an identifier stays with the first dictionary that has it`() throws {
    let shell = try EventCode(parsing: "sysoexec")
    // A word that only Finder has: `Finder window`.
    let own: Code4 = "brow"
    #expect(try Registry.default().terms[own] == nil)
    for name in ["Aaa", "Zzz"] {
        var registry = try Registry.default()
        try registry.add(renaming(name, identifier: "com.apple.Finder"))
        let scoped = registry.scoped(toID: "COM.apple.finder")
        #expect(scoped.commands[shell]?.name == "do shell script" && scoped.terms["shee"] == nil, "\(name)")
        #expect(scoped.terms[own] == "Finder window", "\(name)")
        // By its name, the learned dictionary is found as before.
        #expect(registry.scoped(to: .name(name)).terms["shee"] == "sheep")
    }
    // An identifier that no dictionary has: the learned one gets it.
    var registry = try Registry.default()
    try registry.add(renaming("Zzz", identifier: "org.example.sheep"))
    try registry.add(renaming("Aaa", identifier: "org.example.sheep"))
    #expect(registry.scoped(toID: "org.example.sheep").terms["shee"] == "sheep")
    #expect(registry.scoped(toID: "").terms["shee"] == nil && registry.scoped(toID: "org.example.none").terms["shee"] == nil)
    // A dictionary of the same name with another identifier does not bring it to the built-in one.
    try registry.add(renaming("Finder", identifier: "org.example.wolf"))
    #expect(registry.scoped(toID: "org.example.wolf").terms[own] == nil)
    #expect(registry.scoped(toID: "com.apple.finder").terms[own] == "Finder window")
}

// MARK: - A script that does not load the scripting additions

/**
 A script with a `use` line loads the scripting additions only when it
 says `use scripting additions`. Without that line their words do not
 compile, so the code is written:

 ```
 use framework "Foundation"
 set x to «event sysoexec» "ls"
 ```

 The tool wrote `do shell script "ls"`, which the compiler refuses in
 that script.
 */
@Test func `the words of scripting additions are not known without their use line`() throws {
    let registry = try Registry.default()
    let shell = try EventCode(parsing: "sysoexec")
    let dialog = try EventCode(parsing: "sysodlog")
    #expect(registry.knowsScriptingAdditions && registry.command(shell)?.name == "do shell script")

    let without = registry.using([], scriptingAdditions: false)
    #expect(!without.knowsScriptingAdditions)
    #expect(without.command(shell) == nil && without.command(dialog) == nil && without.scriptCommand(shell) == nil)
    #expect(without.term("btns") == nil && without.parameter("badm") == nil)
    // The words of the language are known as before.
    #expect(without.term("pnam") == "name" && without.term("psxf") == registry.term("psxf"))
    #expect(try without.command(EventCode(parsing: "corecnte"))?.name == "count")
    #expect(try without.scriptCommand(EventCode(parsing: "corecnte"))?.name == "count")
    // Inside a `tell` block the words of the application are known, and still not those of the additions.
    let finder = without.scoped(to: "Finder")
    #expect(finder.term("brow") == "Finder window" && finder.command(shell) == nil && !finder.knowsScriptingAdditions)
    // With `use application`, the same.
    let used = registry.using([.name("Finder")], scriptingAdditions: false)
    #expect(used.term("brow") == "Finder window" && used.command(shell) == nil)
    // Asked twice, it is the same registry; with the additions, nothing changes.
    #expect(without.using([], scriptingAdditions: false).command(shell) == nil)
    #expect(registry.using([]).command(shell)?.name == "do shell script")
    #expect(registry.using([.name("Finder")]).command(dialog)?.name == "display dialog")
}
