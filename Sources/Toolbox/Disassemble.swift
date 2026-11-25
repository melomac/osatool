import Bytecode
import Extensions
import FAS
import Foundation
import Model
import Terminology

/** How `disassemble` works. */
public struct DisassembleOptions: Sendable {
    /** When true, a problem the tool could recover from is an error. */
    public var strict: Bool
    /** Upper bounds for what the file can ask for. */
    public var limits: Limits
    /**
     The dictionaries used to name codes in the comments of the listing.
     `nil` means `ScriptingTerminology.builtIn()`, and no names when the
     program was linked without its terminology.
     */
    public var terminology: ScriptingTerminology?

    public init(strict: Bool = false, limits: Limits = Limits(), terminology: ScriptingTerminology? = nil) {
        self.strict = strict
        self.limits = limits
        self.terminology = terminology
    }
}

/**
 Disassembles a compiled script.

 Root functions come first, then the handlers of each nested script
 object. An instruction gets an annotation for each thing the tool knows
 about it: a short description of a literal, the name of a variable, the
 word of a code (see `ListingComments`).

 - Throws: when the data is not a compiled script, or is a JavaScript
   for Automation (JXA) script, which has no bytecode. In strict mode,
   also on a cut-off instruction.
 */
public func disassemble(_ input: [UInt8], options: DisassembleOptions = DisassembleOptions()) throws -> Disassembly {
    try withLargeStack { try disassembleOnThisThread(input, options: options) }
}

/** Disassembles a compiled script held as `Data`: see `disassemble(_:options:)` for bytes. */
public func disassemble(_ input: Data, options: DisassembleOptions = DisassembleOptions()) throws -> Disassembly {
    try disassemble([UInt8](input), options: options)
}

/** Does the work of `disassemble`, on the stack of the calling thread. */
func disassembleOnThisThread(_ input: [UInt8], options: DisassembleOptions) throws -> Disassembly {
    if isJavaScript(input) {
        throw ScriptError("a JavaScript for Automation (JXA) script holds source text, not bytecode: use 'decompile' to print it")
    }
    let document = try FAS.parse(input, options: ParseOptions(strict: options.strict, limits: options.limits.parseLimits))
    let script = try normalize(document)
    var out = Disassembly(version: String(decoding: document.version, as: UTF8.self), diagnostics: document.diagnostics.map(Diagnostic.init))

    let comments = ListingComments(registry: options.terminology?.registry ?? (try? Registry.default()))

    func appendFunction(_ function: Function, _ owner: String, _ path: String, _ scopes: [[Value]]) throws {
        let decoded = try decode(function.offset, function.code, strict: options.strict)
        var listed = DisassemblyFunction(
            offset: function.offset, name: function.name.summary, arguments: function.arguments.summary,
            owner: owner, path: path,
        )
        out.diagnostics.append(contentsOf: decoded.diagnostics.map(Diagnostic.init))
        for inst in decoded.instructions {
            listed.instructions.append(DisassemblyInstruction(
                offset: inst.offset, opcode: inst.byte, mnemonic: inst.mnemonic, rawHex: inst.raw.hex,
                operands: inst.operands.map { DisassemblyOperand(kind: $0.kind.rawValue, value: $0.value) },
                annotations: comments.comments(for: inst, in: function, scopes: scopes),
            ))
        }
        out.functions.append(listed)
    }

    /** Lists the handlers of a script object, then those of the script objects inside it. */
    func appendScriptObject(_ object: ScriptTable, _ outer: [[Value]]) throws {
        let owner = object.name?.summary ?? object.path
        let scopes = [object.names] + outer
        for function in object.functions {
            try appendFunction(function, owner, "\(object.path)[\(function.offset)]", scopes)
        }
        for inner in object.scriptObjects {
            try appendScriptObject(inner, scopes)
        }
    }

    let rootScope = [script.table.names]
    for function in script.table.functions {
        try appendFunction(function, "", "", rootScope)
    }
    for object in script.table.scriptObjects {
        try appendScriptObject(object, rootScope)
    }
    return out
}
