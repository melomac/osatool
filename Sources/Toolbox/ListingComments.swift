import AST
import Bytecode
import Extensions
import FAS
import Model
import Terminology

/**
 What the listing says after `;` about an instruction: the things the
 tool knows and the bytes do not show.

 ```
 PushLiteral       literal-index=0   ; constant(0x636f626a) 'cobj' item
 MessageSend       literal-index=33  ; event("syso","exec",…) do shell script
 PushLiteral       literal-index=4   ; vector(type=4,len=2) list
 PushVariable      variable-index=1  ; "plistContent"
 MakeObjectAlias                     ; index
 MakeComp                            ; Equal
 ```

 A word of a dictionary is a hint, not source: the code alone does not
 tell whether the script means a class, a property, an enumerator or a
 parameter, so every word the code has is given.
 */
struct ListingComments {
    /** The dictionaries that give words to codes. `nil`: no word is given. */
    var registry: Registry?
    /** The names of the parameters of the commands of Standard Additions. */
    private var additionParameters: [Code4: [String]] = [:]

    init(registry: Registry?) {
        self.registry = registry
        let commands = registry?.dictionary(standardAdditionsName)?.commands.values.sorted { $0.name < $1.name } ?? []
        for command in commands {
            for (code, parameter) in command.parameters where !self.additionParameters[code, default: []].contains(parameter.name) {
                self.additionParameters[code, default: []].append(parameter.name)
            }
        }
    }

    /**
     The comments of one instruction, in this order: what the opcode
     byte selects, then one comment for each operand that has one.

     - `scopes`: the names of the script tables around the function,
       the nearest first. `PushParentVariable` reads them.
     */
    func comments(for instruction: Instruction, in function: Function, scopes: [[Value]]) -> [String] {
        var out: [String] = []
        if let selected = Self.selection(of: instruction.opcode) {
            out.append(selected)
        }
        var depth = 0
        for operand in instruction.operands {
            switch operand.kind {
            case .literalIndex:
                out.append(function.literal(operand.value).map { self.literal($0) } ?? "literal[\(operand.value)] out of range")
            case .parentDepth:
                depth = operand.value
            case .variableIndex:
                let names = depth == 0 ? function.variables : (scopes.indices.contains(depth - 1) ? scopes[depth - 1] : [])
                // A script that is run-only has no names.
                if names.indices.contains(operand.value), names[operand.value].bytes != nil {
                    out.append(names[operand.value].summary)
                }
            case .signedWord, .branchTarget:
                break
            }
        }
        return out
    }

    /**
     What the opcode byte selects, for the two mnemonics that stand for
     several bytes with different meanings:

     ```
     MakeObjectAlias   the form of the specifier: see `SpecifierForm`
     MakeComp          the comparison, named like the opcode of the same number
     ```
     */
    static func selection(of opcode: Opcode) -> String? {
        switch opcode {
        case let .makeObjectAlias(form):
            String(describing: form)
        case let .makeComp(index) where index <= 11:
            Opcode.names[Int(index)]
        default:
            nil
        }
    }

    /** The summary of a literal, then what it means when the tool knows. */
    func literal(_ value: Value) -> String {
        guard let meaning = self.meaning(of: value) else {
            return value.summary
        }
        return value.summary + " " + meaning
    }

    /**
     What a stored value means, or `nil` when its summary says it all.

     ```
     special(0x7a)                  true
     constant(0x636f626a)           'cobj' item
     event("syso","exec",…)         do shell script
     vector(type=4,len=2)           list
     ```
     */
    func meaning(of value: Value) -> String? {
        switch value {
        case let .object(content):
            return self.meaning(of: content)
        case let .special(code):
            return Self.specials[code]
        case let .constant(packed):
            let code = KeywordCode(packed: packed)
            guard code.bytes.isPrintableASCII else {
                return nil
            }
            let text = "'" + String(decoding: code.bytes, as: UTF8.self) + "'"
            let words = self.words(for: code)
            return words.isEmpty ? text : text + " " + words.joined(separator: " / ")
        case let .eventIdentifier(event):
            if event.code == "aevtoapp" {
                return "run"
            }
            return self.registry?.commandAnywhere(event.code)?.name
        case let .vector(vector) where vector.hasType && vector.storedText == nil:
            return Self.classes[vector.type]
        default:
            return nil
        }
    }

    /** Every word the dictionaries have for a code: see the type. */
    private func words(for code: KeywordCode) -> [String] {
        guard let registry else {
            return []
        }
        var words: [String] = []
        func add(_ word: String?) {
            if let word, !word.isEmpty, !words.contains(word) {
                words.append(word)
            }
        }
        switch code {
        case .eight("misccura"):
            add("current application")
        case let .eight(eight):
            add(registry.constant(eight))
        case let .four(four):
            add(registry.term(four))
            add(registry.enumeration(four))
            add(registry.parameter(four))
            self.additionParameters[four]?.forEach { add($0) }
        case .other:
            break
        }
        return words
    }

    /** The runtime special values that have a name. */
    static let specials: [UInt64: String] = [Special.nil: "nil", Special.false: "false", Special.true: "true"]

    /** The runtime classes of typed vectors that the tool knows. */
    static let classes: [UInt8: String] = [4: "list", 15: "script object", 16: "handler", 17: "handler", 19: "it"]
}
