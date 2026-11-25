import Extensions
import Foundation

package let terminologyStoreSchemaVersion = 1

/**
 A file of dictionaries: what the tool knows, or has learned, about the
 words of applications.

 The dictionaries compiled into the tool and the ones a user adds with
 `osatool learn` use this same JSON format:

 ```
 {
   "schema_version": 1,
   "system": "Version 27.3 (Build 26C5047e)",
   "dictionaries": [
     { "name": "Finder",
       "id": "com.apple.finder",
       "sources": ["/System/Library/CoreServices/Finder.app/…/Finder.sdef"],
       "commands":    [{ "code": "fndrgstl", "name": "sort", "direct": true,
                         "parameters": [{ "code": "by  ", "name": "by", "type": "property" }] }],
       "terms":       [{ "code": "cfol", "name": "folder" }],
       "enumerators": [{ "code": "snam", "name": "name" }],
       "constants":   [{ "code": "earrsnam", "name": "name" }] }
   ]
 }
 ```

 Lists are sorted by code, so two versions of a file can be compared.

 A file that only a program reads can be smaller: the same JSON on one
 line without spaces (`compact`), and that text as a zlib stream. The
 terminology inside the tool is stored that way. A store is read from
 any of these forms.
 */
package struct TerminologyStore: Sendable {
    /** The system the files were read on, as free text. */
    package var system: String
    package var dictionaries: [ScriptingDictionary]

    package init(system: String = "", dictionaries: [ScriptingDictionary] = []) {
        self.system = system
        self.dictionaries = dictionaries
    }

    /**
     Reads a store from JSON, or from JSON compressed as a zlib stream.

     - Throws: when the JSON is invalid, has another schema version, or
       holds a code that is not four (or eight) bytes.
     */
    package init(data: Data) throws {
        let file: StoreFile
        do {
            file = try JSONDecoder().decode(StoreFile.self, from: data.isZlibStream ? data.zlibDecompressed() : data)
        } catch let error as ScriptError {
            throw ScriptError("parse terminology store: \(error.message)")
        } catch {
            throw ScriptError("parse terminology store: \(error.localizedDescription)")
        }
        if file.schemaVersion != terminologyStoreSchemaVersion {
            throw ScriptError("unsupported terminology store version \(file.schemaVersion)")
        }
        self.system = file.system ?? ""
        self.dictionaries = try file.dictionaries.map { try $0.dictionary() }
    }

    /**
     Writes the store as JSON: one line for each command, term, enumerator
     and constant, in code order, so that two versions compare line by line.

     - `compact`: write all on one line and without a space.
     */
    package func data(compact: Bool = false) -> Data {
        /** The entries of one table, in code order. */
        func entries<Code: Comparable>(_ table: [(code: Code, text: String, name: String)]) -> [JSONValue] {
            table.sorted { $0.code < $1.code }.map { .line(.object([("code", .string($0.text)), ("name", .string($0.name))])) }
        }
        let dictionaries = self.dictionaries.map { dictionary -> JSONValue in
            let commands = dictionary.commands.values.sorted { $0.code.rawValue < $1.code.rawValue }.map { command -> JSONValue in
                var fields: [(String, JSONValue)] = [("code", .string(command.code.text)), ("name", .string(command.name))]
                if command.hasDirectParameter {
                    fields.append(("direct", .boolean(true)))
                }
                let parameters = command.parameterOrder.compactMap { code in
                    command.parameters[code].map { parameter -> JSONValue in
                        var fields: [(String, JSONValue)] = [("code", .string(code.text)), ("name", .string(parameter.name))]
                        if !parameter.type.isEmpty {
                            fields.append(("type", .string(parameter.type)))
                        }
                        return .object(fields)
                    }
                }
                if !parameters.isEmpty {
                    fields.append(("parameters", .array(parameters)))
                }
                return .line(.object(fields))
            }
            let lists: [(String, [JSONValue])] = [
                ("sources", dictionary.sources.map { .string($0) }),
                ("commands", commands),
                ("terms", entries(dictionary.terms.map { ($0.key.rawValue, $0.key.text, $0.value) })),
                ("enumerators", entries(dictionary.enums.map { ($0.key.rawValue, $0.key.text, $0.value) })),
                ("constants", entries(dictionary.constants.map { ($0.key.rawValue, $0.key.text, $0.value) })),
                ("plurals", entries(dictionary.plurals.map { ($0.key.rawValue, $0.key.text, $0.value) })),
                ("reserved_words", dictionary.reservedWords.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { .string($0) }),
            ]
            // A list with nothing in it is left out.
            let identifier: [(String, JSONValue)] = dictionary.bundleID.isEmpty ? [] : [("id", .string(dictionary.bundleID))]
            return .object([("name", .string(dictionary.name))] + identifier + lists.filter { !$0.1.isEmpty }.map { ($0.0, .array($0.1)) })
        }
        var root: [(String, JSONValue)] = [("schema_version", .number(terminologyStoreSchemaVersion))]
        if !self.system.isEmpty {
            root.append(("system", .string(self.system)))
        }
        root.append(("dictionaries", .array(dictionaries)))
        return Data(JSONValue.object(root).text(compact: compact).utf8)
    }

    /**
     Adds dictionaries. One that has the name of a dictionary already in
     the store takes its place. The result is sorted by name.
     */
    package mutating func replace(with dictionaries: [ScriptingDictionary]) {
        var byName: [String: ScriptingDictionary] = [:]
        for dictionary in self.dictionaries + dictionaries {
            byName[dictionary.name] = dictionary
        }
        self.dictionaries = byName.values.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
    }
}

extension ScriptingDictionary {
    /**
     Takes out every code that the registry has a word for outside any
     `tell` block: the codes of the language and of the scripting
     additions. A code is one thing for a class, a property and an
     enumerator, so a word for one of them takes out the others too.
     A plural goes with its word.
     */
    mutating func removeWords(knownTo registry: Registry) {
        self.commands = self.commands.filter { registry.commands[$0.key] == nil }
        let isFree: (Code4) -> Bool = { registry.terms[$0] == nil && registry.enums[$0] == nil }
        self.terms = self.terms.filter { isFree($0.key) }
        self.enums = self.enums.filter { isFree($0.key) }
        self.constants = self.constants.filter { registry.constants[$0.key] == nil }
        self.plurals = self.plurals.filter { self.terms[$0.key] != nil }
    }
}

package extension ScriptingDictionary {
    /**
     Adds the content of another dictionary. A code that is already
     defined keeps its meaning.
     */
    mutating func merge(_ other: ScriptingDictionary) {
        self.sources.append(contentsOf: other.sources.filter { !self.sources.contains($0) })
        self.commands.merge(other.commands) { current, _ in current }
        self.terms.merge(other.terms) { current, _ in current }
        self.enums.merge(other.enums) { current, _ in current }
        self.constants.merge(other.constants) { current, _ in current }
        self.plurals.merge(other.plurals) { current, _ in current }
        self.reservedWords.formUnion(other.reservedWords)
        if self.bundleID.isEmpty {
            self.bundleID = other.bundleID
        }
    }
}

// MARK: - The JSON layout

private struct StoreFile: Decodable {
    var schemaVersion: Int
    var system: String?
    var dictionaries: [StoreDictionary]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case system, dictionaries
    }
}

private struct StoreEntry: Decodable {
    var code: String
    var name: String
}

private struct StoreParameter: Decodable {
    var code: String
    var name: String
    var type: String?
}

private struct StoreCommand: Decodable {
    var code: String
    var name: String
    var direct: Bool?
    var parameters: [StoreParameter]?
}

private struct StoreDictionary: Decodable {
    var name: String
    var id: String?
    var sources: [String]?
    var commands: [StoreCommand]?
    var terms: [StoreEntry]?
    var enumerators: [StoreEntry]?
    var constants: [StoreEntry]?
    var plurals: [StoreEntry]?
    var reservedWords: [String]?

    enum CodingKeys: String, CodingKey {
        case name, id, sources, commands, terms, enumerators, constants, plurals
        case reservedWords = "reserved_words"
    }

    func dictionary() throws -> ScriptingDictionary {
        var dictionary = ScriptingDictionary(name: self.name, sources: self.sources ?? [])
        dictionary.reservedWords = Set(self.reservedWords ?? [])
        dictionary.bundleID = self.id ?? ""
        do {
            for item in self.commands ?? [] {
                var command = try Command(code: EventCode(parsing: item.code), name: item.name, hasDirectParameter: item.direct ?? false)
                for parameter in item.parameters ?? [] {
                    let code = try Code4(parsing: parameter.code)
                    command.parameters[code] = CommandParameter(code: code, name: parameter.name, type: parameter.type ?? "")
                    command.parameterOrder.append(code)
                }
                dictionary.commands[command.code] = command
            }
            for item in self.terms ?? [] {
                try dictionary.terms[Code4(parsing: item.code)] = item.name
            }
            for item in self.enumerators ?? [] {
                try dictionary.enums[Code4(parsing: item.code)] = item.name
            }
            for item in self.constants ?? [] {
                try dictionary.constants[EventCode(parsing: item.code)] = item.name
            }
            for item in self.plurals ?? [] {
                try dictionary.plurals[Code4(parsing: item.code)] = item.name
            }
        } catch {
            throw ScriptError("terminology store, dictionary \(self.name.quoted): \(error.message)")
        }
        return dictionary
    }
}
