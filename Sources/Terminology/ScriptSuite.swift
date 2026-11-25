import Extensions
import Foundation

/**
 Reads the older form of a scripting definition: a pair of property list
 files with the same name.

 ```
 Name.scriptSuite          codes:  class, attribute, command, argument,
                                   enumeration  →  four-character code
 Name.scriptTerminology    words:  the same keys  →  the name a script uses
 ```

 The two files use the same keys, so each code is joined with its name:

 ```
 suite:        Classes.Document.AppleEventCode             = "docu"
 terminology:  Classes.Document.Name                       = "document"   →  term 'docu' = document

 suite:        Commands.Copy.AppleEventClassCode + …Code   = "core" "clon"
 terminology:  Commands.Copy.Name                          = "duplicate"  →  command coreclon = duplicate
 ```

 An entry with no name in the terminology file, or with a code that is
 not four bytes, is left out.

 - Throws: when a file is not a property list.
 */
package func parseScriptSuite(name: String, suite: Data, terminology: Data) throws -> ScriptingDictionary {
    func propertyList(_ data: Data, _ kind: String) throws -> [String: Any] {
        do {
            let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dictionary = value as? [String: Any] else {
                throw ScriptError("the top level is not a dictionary")
            }
            return dictionary
        } catch {
            throw ScriptError("parse \(name) \(kind): \((error as? ScriptError)?.message ?? error.localizedDescription)")
        }
    }
    let codes = try propertyList(suite, "script suite")
    let words = try propertyList(terminology, "script terminology")
    var dictionary = ScriptingDictionary(name: name)

    func table(_ value: Any?, _ key: String) -> [String: Any] {
        (value as? [String: Any])?[key] as? [String: Any] ?? [:]
    }
    func text(_ value: Any?, _ key: String) -> String? {
        (value as? [String: Any])?[key] as? String
    }
    func sorted(_ table: [String: Any]) -> [(key: String, value: Any)] {
        table.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }

    // Each table of words is taken once, before the loop that uses it.
    // Taking it again for each entry made the reading slow: a table
    // from a property list is copied each time, and 20,000 classes took
    // 34 seconds.
    let allClassWords = table(words, "Classes")
    for (className, classCodes) in sorted(table(codes, "Classes")) {
        let classWords = allClassWords[className]
        if let code = text(classCodes, "AppleEventCode").flatMap({ try? Code4(parsing: $0) }),
           let name = text(classWords, "Name"), dictionary.terms[code] == nil
        {
            dictionary.terms[code] = name
        }
        for group in ["Attributes", "ToOneRelationships", "ToManyRelationships"] {
            let memberWords = table(classWords, group)
            for (member, memberCodes) in sorted(table(classCodes, group)) {
                if let code = text(memberCodes, "AppleEventCode").flatMap({ try? Code4(parsing: $0) }),
                   let name = text(memberWords[member], "Name"), dictionary.terms[code] == nil
                {
                    dictionary.terms[code] = name
                }
            }
        }
    }

    // A class the suite has no object for, like `paragraph` in the text
    // suite: the terminology names it by its code.
    for (codeText, synonym) in sorted(table(words, "Synonyms")) {
        guard
            let code = try? Code4(parsing: codeText),
            let name = text(synonym, "Name"),
            dictionary.terms[code] == nil
        else {
            continue
        }
        dictionary.terms[code] = name
        if let plural = text(synonym, "PluralName") {
            dictionary.plurals[code] = plural
        }
    }

    let allCommandWords = table(words, "Commands")
    for (commandName, commandCodes) in sorted(table(codes, "Commands")) {
        let commandWords = allCommandWords[commandName]
        guard
            let classCode = text(commandCodes, "AppleEventClassCode"),
            let idCode = text(commandCodes, "AppleEventCode"),
            let code = try? EventCode(parsing: classCode + idCode),
            let name = text(commandWords, "Name")
        else {
            continue
        }
        var command = Command(code: code, name: name, hasDirectParameter: (commandCodes as? [String: Any])?["UnnamedArgument"] != nil)
        var parameters: [CommandParameter] = []
        let argumentWords = table(commandWords, "Arguments")
        for (argument, argumentCodes) in sorted(table(commandCodes, "Arguments")) {
            if let code = text(argumentCodes, "AppleEventCode").flatMap({ try? Code4(parsing: $0) }),
               let name = text(argumentWords[argument], "Name")
            {
                // The decompiler prints a boolean argument as `with` / `without`.
                let type = text(argumentCodes, "Type") == "NSNumber<Bool>" ? "boolean" : (text(argumentCodes, "Type") ?? "")
                parameters.append(CommandParameter(code: code, name: name, type: type))
            }
        }
        for parameter in parameters.sorted(by: { $0.code.rawValue < $1.code.rawValue }) where command.parameters[parameter.code] == nil {
            command.parameters[parameter.code] = parameter
            command.parameterOrder.append(parameter.code)
        }
        if dictionary.commands[code] == nil {
            dictionary.commands[code] = command
        }
    }

    let allEnumerationWords = table(words, "Enumerations")
    for (enumeration, enumerationCodes) in sorted(table(codes, "Enumerations")) {
        let group = text(enumerationCodes, "AppleEventCode") ?? ""
        let enumeratorWords = allEnumerationWords[enumeration] as? [String: Any] ?? [:]
        for (enumerator, value) in sorted(table(enumerationCodes, "Enumerators")) {
            guard
                let codeText = value as? String,
                let code = try? Code4(parsing: codeText),
                let name = text(enumeratorWords[enumerator], "Name")
            else {
                continue
            }
            if dictionary.enums[code] == nil {
                dictionary.enums[code] = name
            }
            if let constant = try? EventCode(parsing: group + codeText) {
                dictionary.constants[constant] = name
            }
        }
    }
    return dictionary
}
