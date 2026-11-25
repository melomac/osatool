import Extensions
import Foundation

let languageSchemaVersion = 1

/** The name of the dictionary that holds the words of the language itself. */
package let languageDictionaryName = "AppleScript Language"

/**
 The content of `language.json`, generated from AppleScript's system
 terminology (`OSAGetSysTerminology`).

 Terms, enumerations and command parameters stay in separate lists,
 because the same four-byte code can have a different name in each one.

 The file is only read: `parseLanguageDefinition` turns it into a
 dictionary. A key that is missing reads as empty.
 */
struct LanguageDefinition: Decodable {
    var schemaVersion: Int
    var source: String
    var commands: [LanguageCommand]
    var terms: [LanguageTerm]
    var enumerations: [LanguageTerm]
    /**
     The words that cannot be the name of a variable without bars, in
     lower case. `Scripts/reserved-words.py` asks the compiler for them.
     */
    var reservedWords: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reservedWords = "reserved_words"
        case source, commands, terms, enumerations
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        self.commands = try container.decodeIfPresent([LanguageCommand].self, forKey: .commands) ?? []
        self.terms = try container.decodeIfPresent([LanguageTerm].self, forKey: .terms) ?? []
        self.enumerations = try container.decodeIfPresent([LanguageTerm].self, forKey: .enumerations) ?? []
        self.reservedWords = try container.decodeIfPresent([String].self, forKey: .reservedWords) ?? []
    }
}

struct LanguageCommand: Decodable {
    var code: String
    var name: String
    var hasDirectParameter: Bool
    var parameters: [LanguageParameter]

    enum CodingKeys: String, CodingKey {
        case code, name, parameters
        case hasDirectParameter = "has_direct_parameter"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.hasDirectParameter = try container.decodeIfPresent(Bool.self, forKey: .hasDirectParameter) ?? false
        self.parameters = try container.decodeIfPresent([LanguageParameter].self, forKey: .parameters) ?? []
    }
}

struct LanguageParameter: Decodable {
    var code: String
    var name: String
    var type: String

    enum CodingKeys: String, CodingKey {
        case code, name, type
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    }
}

struct LanguageTerm: Decodable {
    /** For an enumerator: the code of the enumeration it belongs to. */
    var group: String
    var code: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case group, code, name
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.group = try container.decodeIfPresent(String.self, forKey: .group) ?? ""
        self.code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/**
 Reads `language.json` and returns the language dictionary.

 An enumerator with a `group` is stored twice: under its own four-byte
 code (`enums`), and under group + code (`constants`).

 - Throws: when the JSON is invalid, has another schema version, or holds
   a code that is not four (or eight) bytes.
 */
package func parseLanguageDefinition(_ data: Data) throws -> ScriptingDictionary {
    let definition: LanguageDefinition
    do {
        definition = try JSONDecoder().decode(LanguageDefinition.self, from: data)
    } catch {
        throw ScriptError("parse AppleScript language terminology: \(error.localizedDescription)")
    }
    if definition.schemaVersion != languageSchemaVersion {
        throw ScriptError("unsupported AppleScript language terminology version \(definition.schemaVersion)")
    }
    var dictionary = ScriptingDictionary(name: languageDictionaryName, plurals: languagePlurals)
    dictionary.reservedWords = Set(definition.reservedWords.map { $0.lowercased() })
    for item in definition.commands {
        let code: EventCode
        do {
            code = try EventCode(parsing: item.code)
        } catch {
            throw ScriptError("language command \(item.name.quoted): \(error.message)")
        }
        var command = Command(code: code, name: item.name, hasDirectParameter: item.hasDirectParameter)
        for parameter in item.parameters {
            let parameterCode: Code4
            do {
                parameterCode = try Code4(parsing: parameter.code)
            } catch {
                throw ScriptError("language command \(command.name.quoted) parameter \(parameter.name.quoted): \(error.message)")
            }
            command.parameters[parameterCode] = CommandParameter(code: parameterCode, name: parameter.name, type: parameter.type)
            command.parameterOrder.append(parameterCode)
        }
        dictionary.commands[code] = command
    }
    for item in definition.terms {
        do {
            try dictionary.terms[Code4(parsing: item.code)] = item.name
        } catch {
            throw ScriptError("language term \(item.name.quoted): \(error.message)")
        }
    }
    for item in definition.enumerations {
        let code: Code4
        do {
            code = try Code4(parsing: item.code)
        } catch {
            throw ScriptError("language enumeration \(item.name.quoted): \(error.message)")
        }
        if dictionary.enums[code] == nil {
            dictionary.enums[code] = item.name
        }
        if !item.group.isEmpty {
            do {
                try dictionary.constants[EventCode(parsing: item.group + item.code)] = item.name
            } catch {
                throw ScriptError("language enumeration \(item.name.quoted) group \(item.group.quoted): \(error.message)")
            }
        }
    }
    return dictionary
}

/**
 The classes of the language whose name is also their plural. After
 `of`, the compiler reads such a word as every one of them:

 ```
 text of x              every text of x
 styled text of x       every styled text of x
 Unicode text of x      not one: a property of x
 ```

 `Unicode text` is in `languagePlurals` because a range is written
 with it, but it is not its own plural.
 */
let languageOwnPlurals: Set<Code4> = ["ctxt", "STXT", "itxt"]

/**
 The plural names of the classes of the language. The language file has
 only the singular names. A range is written with the plural:
 `items 2 thru 4 of x`.
 */
let languagePlurals: [Code4: String] = [
    "cobj": "items", "cha ": "characters", "cwor": "words", "cpar": "paragraphs", "citm": "text items",
    "ctxt": "text", "TEXT": "strings", "utxt": "Unicode text", "list": "lists", "reco": "records",
    "long": "integers", "doub": "reals", "nmbr": "numbers", "bool": "booleans", "ldt ": "dates",
    "alis": "aliases", "file": "files", "furl": "file URLs", "pcls": "classes", "scpt": "scripts",
    "capp": "applications", "cRGB": "RGB colors", "type": "classes",
]
