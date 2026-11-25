import Bytecode
import Extensions

/** The version of the JSON form of a listing. */
public let disassemblySchemaVersion = 1

/** The listing of a compiled script: every function with its instructions. */
public struct Disassembly: Sendable {
    public var schemaVersion: Int
    /** The format version read from the file, for example `1.10`. */
    public var version: String
    public var functions: [DisassemblyFunction]
    public var diagnostics: [Diagnostic]

    public init(schemaVersion: Int = disassemblySchemaVersion, version: String = "", functions: [DisassemblyFunction] = [], diagnostics: [Diagnostic] = []) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.functions = functions
        self.diagnostics = diagnostics
    }
}

public struct DisassemblyFunction: Sendable {
    /** The slot of the function in its table. */
    public var offset: Int
    public var name: String
    public var arguments: String
    /** For a handler of a nested script object: the name of that object. */
    public var owner: String
    /** For a handler of a nested script object: where it was found. */
    public var path: String
    public var instructions: [DisassemblyInstruction]

    public init(offset: Int, name: String, arguments: String, owner: String = "", path: String = "", instructions: [DisassemblyInstruction] = []) {
        self.offset = offset
        self.name = name
        self.arguments = arguments
        self.owner = owner
        self.path = path
        self.instructions = instructions
    }
}

/** The kind and value of one instruction operand. */
public struct DisassemblyOperand: Sendable, Equatable {
    /** `signed-word`, `literal-index`, `variable-index`, `parent-depth` or `branch-target`. */
    public var kind: String
    public var value: Int

    public init(kind: String, value: Int) {
        self.kind = kind
        self.value = value
    }
}

public struct DisassemblyInstruction: Sendable {
    /** Position of the opcode byte inside the function's code. */
    public var offset: Int
    public var opcode: UInt8
    public var mnemonic: String
    /** The instruction bytes as hexadecimal text. */
    public var rawHex: String
    public var operands: [DisassemblyOperand]
    /**
     What the tool knows about the instruction, as short texts: the
     meaning of the opcode byte when the mnemonic does not tell it, then
     a description of each literal and the name of each variable the
     instruction refers to.
     */
    public var annotations: [String]

    public init(offset: Int, opcode: UInt8, mnemonic: String, rawHex: String, operands: [DisassemblyOperand] = [], annotations: [String] = []) {
        self.offset = offset
        self.opcode = opcode
        self.mnemonic = mnemonic
        self.rawHex = rawHex
        self.operands = operands
        self.annotations = annotations
    }
}

public extension Disassembly {
    /**
     Returns the listing as text. One line per instruction:

     ```
     FAS 1.10

     function[2] "run" arguments=nil
       00000  e0           PushLiteral              literal-index=0  ; "hello"
       00001  59000a       Jump                     branch-target=0xd
     ```

     Columns: offset, raw bytes, mnemonic, operands, then annotations
     after `;`.
     */
    func text() -> String {
        var out = "FAS \(version)\n"
        for function in self.functions {
            out += "\nfunction[\(function.offset)] \(function.name) arguments=\(function.arguments)"
            if !function.owner.isEmpty {
                out += " owner=\(function.owner)"
            }
            if !function.path.isEmpty {
                out += " path=\(function.path)"
            }
            out += "\n"
            for inst in function.instructions {
                out += "  \(inst.offset.hex(width: 5))  \(inst.rawHex.padded(to: 12)) \(inst.mnemonic.padded(to: 24))"
                for (index, operand) in inst.operands.enumerated() {
                    if index > 0 {
                        out += ", "
                    }
                    out += "\(operand.kind)=\(operand.text)"
                }
                if !inst.annotations.isEmpty {
                    out += "  ; "
                    out += inst.annotations.joined(separator: ", ")
                }
                out += "\n"
            }
        }
        return out
    }

    /**
     Returns the listing as JSON, indented with two spaces and ending with
     a line feed.

     Keys come in a fixed order, and a field that is empty and optional
     (`owner`, `path`, `operands`, `annotations`, `diagnostics`, a zero
     `offset` or `function` of a diagnostic) is left out.
     */
    func json() -> String {
        var root: [(String, JSONValue)] = [
            ("schema_version", .number(schemaVersion)),
            ("fas_version", .string(version)),
            ("functions", .array(functions.map { function in
                var fields: [(String, JSONValue)] = [
                    ("offset", .number(function.offset)),
                    ("name", .string(function.name)),
                    ("arguments", .string(function.arguments)),
                ]
                if !function.owner.isEmpty {
                    fields.append(("owner", .string(function.owner)))
                }
                if !function.path.isEmpty {
                    fields.append(("path", .string(function.path)))
                }
                fields.append(("instructions", .array(function.instructions.map { inst in
                    var fields: [(String, JSONValue)] = [
                        ("offset", .number(inst.offset)),
                        ("opcode", .number(Int(inst.opcode))),
                        ("mnemonic", .string(inst.mnemonic)),
                        ("raw_hex", .string(inst.rawHex)),
                    ]
                    if !inst.operands.isEmpty {
                        fields.append(("operands", .array(inst.operands.map {
                            .object([("kind", .string($0.kind)), ("value", .number($0.value))])
                        })))
                    }
                    if !inst.annotations.isEmpty {
                        fields.append(("annotations", .array(inst.annotations.map { .string($0) })))
                    }
                    return .object(fields)
                })))
                return .object(fields)
            })),
        ]
        if !self.diagnostics.isEmpty {
            // Schema version 1 has a severity, which is always 1 (a
            // warning). It writes -1 for a position that is not known,
            // and leaves out a position that is 0.
            root.append(("diagnostics", .array(self.diagnostics.map { item in
                var fields: [(String, JSONValue)] = [
                    ("severity", .number(1)),
                    ("stage", .string(item.stage.rawValue)),
                ]
                let offset = item.offset ?? -1
                if offset != 0 {
                    fields.append(("offset", .number(offset)))
                }
                let function = item.function ?? -1
                if function != 0 {
                    fields.append(("function", .number(function)))
                }
                if let opcode = item.opcode {
                    fields.append(("opcode", .number(Int(opcode))))
                }
                fields.append(("message", .string(item.message)))
                return .object(fields)
            })))
        }
        // The listing escapes `<`, `>` and `&`, as schema version 1 does.
        return JSONValue.object(root).text(escapesHTML: true)
    }
}

extension DisassemblyOperand {
    /** The value as the listing prints it: a branch target in hexadecimal, any other value in decimal. */
    var text: String {
        if self.kind == OperandKind.branchTarget.rawValue {
            return "0x" + self.value.hex
        }
        return String(self.value)
    }
}
