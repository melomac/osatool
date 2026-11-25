import AST
import Decompilation
import Extensions
import FAS
import Foundation
import Model
import Passes
import Terminology

/**
 How `decompile` works.

 ```swift
 var options = DecompileOptions()
 options.passes = [.strings]
 options.limits.maxInputBytes = 1 << 20
 ```
 */
public struct DecompileOptions: Sendable {
    /** When true, any diagnostic makes the call fail. */
    public var strict: Bool
    /** When true, a compiled script stored inside the script is not opened. */
    public var disableEmbeddedUnwrap: Bool
    /** Upper bounds for what the file can ask for. */
    public var limits: Limits
    /** The dictionaries used to name codes. `nil` means `ScriptingTerminology.builtIn()`. */
    public var terminology: ScriptingTerminology?
    /** Passes applied to the syntax tree, in order, before printing. */
    public var passes: [DecompilePass]

    public init(
        strict: Bool = false, disableEmbeddedUnwrap: Bool = false, limits: Limits = Limits(),
        terminology: ScriptingTerminology? = nil, passes: [DecompilePass] = [],
    ) {
        self.strict = strict
        self.disableEmbeddedUnwrap = disableEmbeddedUnwrap
        self.limits = limits
        self.terminology = terminology
        self.passes = passes
    }
}

/** A change made to the syntax tree after decompilation and before printing. */
public enum DecompilePass: String, CaseIterable, Sendable {
    /**
     Puts back together text that a script cut into pieces to hide it:
     `"cu" & "rl"` becomes `"curl"`, and `ASCII character 45` becomes `"-"`.
     */
    case strings

    /** The pass of this name. */
    package func pass() throws -> any Pass {
        try Passes.named(self.rawValue)
    }
}

/** The language a script is written in. The raw value is the name `osacompile -l` takes. */
public enum ScriptLanguage: String, Sendable {
    case appleScript = "AppleScript"
    /** JavaScript for Automation (JXA). */
    case javaScript = "JavaScript"
}

/**
 What `decompile` gives back. The syntax tree is not part of it: the
 tree can be very deep, and it is made and freed on the thread that
 does the work (see `withLargeStack`).
 */
public struct DecompileResult: Sendable {
    /** The source text. */
    public var source: String
    /** The problems the tool recovered from. */
    public var diagnostics: [Diagnostic]
    /** True when the result comes from a script stored inside the input. */
    public var embedded: Bool
    /** The language of the source text. */
    public var language: ScriptLanguage

    public init(
        source: String = "", diagnostics: [Diagnostic] = [], embedded: Bool = false, language: ScriptLanguage = .appleScript,
    ) {
        self.source = source
        self.diagnostics = diagnostics
        self.embedded = embedded
        self.language = language
    }

    /**
     The AppleScript source text as data, in UTF-8: the form to write to
     a file or to a pipe, or to hash. `source` is the same text as a
     `String`, the form to show or to search.
     */
    public var sourceData: Data {
        Data(self.source.utf8)
    }
}

/**
 Thrown in strict mode when decompilation finished but reported
 diagnostics. It carries the source text that was produced and those
 diagnostics.
 */
public struct StrictDecompilationError: LocalizedError, CustomStringConvertible, Sendable {
    /** The source text that was produced. */
    public var source: String
    public var diagnostics: [Diagnostic]

    public init(source: String, diagnostics: [Diagnostic]) {
        self.source = source
        self.diagnostics = diagnostics
    }

    /** The source text that was produced, as data in UTF-8: see `DecompileResult.sourceData`. */
    public var sourceData: Data {
        Data(self.source.utf8)
    }

    public var description: String {
        "strict decompilation produced \(self.diagnostics.count) diagnostics"
    }

    public var errorDescription: String? {
        self.description
    }
}

/**
 Decompiles a compiled script (`.scpt`) to AppleScript source. The
 script is only read: nothing in it is run.

 ```
 bytes ─ FAS.parse ─▶ object graph ─ Model.normalize ─▶ function tables
       ─ Decompilation.run ─▶ syntax tree ─ passes ─▶ syntax tree
       ─ AST.format ─▶ source text
 ```

 Some scripts only carry another compiled script as data (a loader).
 Unless `disableEmbeddedUnwrap` is set, that inner script is decompiled
 instead, and `embedded` is true in the result. Up to eight scripts
 stored one inside the other are opened that way.

 A compiled JavaScript for Automation (JXA) script has no bytecode: it
 holds its source text, also when it is run-only. The result is that
 text as it is stored, and its `language` is `.javaScript`. The options
 other than `limits.maxInputBytes` have no use for such a script.

 The work is done on another thread with a large stack, and the call
 waits for it: it can be made from any thread.

 - Throws: when the data is not a compiled script; in strict mode, on any
   problem (`StrictDecompilationError` when source text exists).
 */
public func decompile(_ input: [UInt8], options: DecompileOptions = DecompileOptions()) throws -> DecompileResult {
    try withLargeStack { try decompileOnThisThread(input, options: options) }
}

/** Decompiles a compiled script held as `Data`: see `decompile(_:options:)` for bytes. */
public func decompile(_ input: Data, options: DecompileOptions = DecompileOptions()) throws -> DecompileResult {
    try decompile([UInt8](input), options: options)
}

/**
 How many scripts stored one inside the other are opened. A loader
 around a loader is rare; a file made of thousands of them, each around
 the next, would be read thousands of times.
 */
let maximumEmbeddedScripts = 8

/**
 Does the work of `decompile`, on the stack of the calling thread.

 - `opened`: how many scripts around this one were opened to reach it.
 */
func decompileOnThisThread(_ input: [UInt8], options: DecompileOptions, opened: Int = 0) throws -> DecompileResult {
    if isJavaScript(input) {
        return try DecompileResult(source: javaScriptSource(input, limits: options.limits.parseLimits), language: .javaScript)
    }
    let terms = try options.terminology?.registry ?? Registry.default()
    let passes = try options.passes.map { try $0.pass() }
    let document = try FAS.parse(input, options: ParseOptions(strict: options.strict, limits: options.limits.parseLimits))
    if !options.disableEmbeddedUnwrap, let payload = document.root.embeddedScript {
        if opened >= maximumEmbeddedScripts {
            throw ScriptError("more than \(maximumEmbeddedScripts) scripts are stored one inside the other")
        }
        var nested = try decompileOnThisThread(payload, options: options, opened: opened + 1)
        nested.embedded = true
        return nested
    }
    let script = try normalize(document)
    let rebuilt = try Decompilation.run(script, options: RebuildOptions(strict: options.strict, terms: terms))
    var tree = rebuilt.script
    var result = DecompileResult(diagnostics: (document.diagnostics + rebuilt.diagnostics).map(Diagnostic.init))
    for pass in passes {
        let (rewritten, diagnostics) = pass.rewrite(tree)
        tree = rewritten
        // The note of a pass starts with the name of the pass.
        for var item in diagnostics {
            item.message = "\(pass.name): \(item.message)"
            result.diagnostics.append(Diagnostic(item))
        }
    }
    result.source = format(tree, terms: terms)
    if options.strict, !result.diagnostics.isEmpty {
        throw StrictDecompilationError(source: result.source, diagnostics: result.diagnostics)
    }
    return result
}

extension Value {
    /**
     A compiled script stored as raw data inside the object graph, when
     there is one.

     Such a block starts with the bytes `scptFasd`: the data type `scpt`,
     then the magic of a compiled script. The value is the inner script
     (from `Fasd` on).
     */
    var embeddedScript: [UInt8]? {
        // The values still to visit wait in a list: a long list does not use the stack.
        var seen = Visited()
        var waiting = [self]
        while let value = waiting.popLast() {
            if case let .rawData(data) = value, data.count >= 8, data[..<8].elementsEqual("scptFasd".utf8) {
                return Array(data[4...])
            }
            if seen.enter(value) {
                value.appendChildren(to: &waiting, alsoData: true)
            }
        }
        return nil
    }
}
