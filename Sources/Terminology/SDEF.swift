import Extensions
import Foundation

/** One XML element: its name, its attributes and its child elements. */
struct XMLNode {
    var name = ""
    var attributes: [String: String] = [:]
    var nodes: [XMLNode] = []

    func attr(_ name: String) -> String {
        self.attributes[name] ?? ""
    }
}

/**
 The deepest element that is kept. The terms of a definition are a few
 levels deep:

 ```
 dictionary › suite › class › property › synonym          5 levels
 dictionary › suite › command › parameter › type          5 levels
 ```

 A file can nest elements as deep as it is long, and the tree is read
 by a function that calls itself for each level: 2,000 levels ended the
 program. What is deeper than this limit is not kept; it cannot be a
 term.
 */
package let maximumElementDepth = 16

/**
 Builds the tree of the first root element with Foundation's SAX parser.
 Elements deeper than `maximumElementDepth` are left out.
 */
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var stack: [XMLNode] = []
    var root: XMLNode?
    /** The number of elements that are open, also those that are left out. */
    var depth = 0

    /** Keeps the part after the namespace prefix: `xi:include` → `include`. */
    static func local(_ name: String) -> String {
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }

    func parser(
        _: XMLParser, didStartElement elementName: String, namespaceURI _: String?,
        qualifiedName _: String?, attributes attributeDict: [String: String] = [:],
    ) {
        self.depth += 1
        if self.depth > maximumElementDepth {
            return
        }
        var node = XMLNode(name: XMLTreeBuilder.local(elementName))
        for (key, value) in attributeDict {
            let name = XMLTreeBuilder.local(key)
            if key == name || node.attributes[name] == nil {
                node.attributes[name] = value
            }
        }
        self.stack.append(node)
    }

    func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        self.depth -= 1
        guard
            self.depth < maximumElementDepth,
            let node = stack.popLast()
        else {
            return
        }
        if self.stack.isEmpty {
            if self.root == nil {
                self.root = node
            }
        } else {
            self.stack[self.stack.count - 1].nodes.append(node)
        }
    }
}

/**
 Reads a scripting definition (`.sdef`, the XML that `/usr/bin/sdef`
 prints) and returns its terms.

 The elements that matter:

 ```
 <command name code>                      → commands
     <direct-parameter>                   → hasDirectParameter
     <parameter name code type>           → parameters
 <class|class-extension|property|type>    → terms
 <record-type|value-type>                 → terms    (`dialog reply`, `specifier`)
     <synonym code>                       → terms    (a second code for the word)
 <enumeration code>
     <enumerator name code>               → enums and constants
 ```

 Inside one dictionary the first definition of a term wins, and the last
 definition of a command wins.

 - Throws: when the XML is not well formed or a command code is invalid.
 */
package func parseSDEF(name: String, data: Data) throws -> ScriptingDictionary {
    try parseSDEFDocument(name: name, data: data).dictionary
}

/**
 Reads a scripting definition, and also returns the files it includes.

 A definition can take suites from another file. Many applications
 take the standard suite (`window`, `document`, `close`…) that way:

 ```
 <xi:include href="file:///System/Library/ScriptingDefinitions/CocoaStandard.sdef"
             xpointer="xpointer(/dictionary/suite)"/>
 ```

 This function reads no other file: it returns each `href` as it is
 written. `scanTerminology` reads the files.
 */
package func parseSDEFDocument(name: String, data: Data) throws -> (dictionary: ScriptingDictionary, includes: [String]) {
    let builder = XMLTreeBuilder()
    let parser = XMLParser(data: data)
    parser.delegate = builder
    parser.shouldProcessNamespaces = false
    parser.shouldResolveExternalEntities = false
    if !parser.parse() || builder.root == nil {
        let reason = parser.parserError.map(\.localizedDescription) ?? "EOF"
        throw ScriptError("parse \(name) SDEF: \(reason)")
    }
    var dictionary = ScriptingDictionary(name: name)
    var includes: [String] = []

    func walk(_ node: XMLNode) throws {
        switch node.name {
        case "include":
            let href = node.attr("href")
            if !href.isEmpty {
                includes.append(href)
            }
        case "command":
            let codeText = node.attr("code")
            if !codeText.isEmpty {
                let code = try EventCode(parsing: codeText)
                var command = Command(code: code, name: node.attr("name"))
                for child in node.nodes {
                    switch child.name {
                    case "direct-parameter":
                        command.hasDirectParameter = true
                    case "parameter":
                        let codeText = child.attr("code")
                        let parameterName = child.attr("name")
                        if codeText.isEmpty || parameterName.isEmpty {
                            continue
                        }
                        let parameterCode = try Code4(parsing: codeText)
                        // A code can come twice, with two spellings: `using delimiter`
                        // and `using delimiters`. The first one is the one printed.
                        if command.parameters[parameterCode] == nil {
                            command.parameters[parameterCode] = CommandParameter(code: parameterCode, name: parameterName, type: child.attr("type"))
                            command.parameterOrder.append(parameterCode)
                        }
                    default:
                        break
                    }
                }
                dictionary.commands[code] = command
            }
        // `contents` is a property too: `selected tab` of a Terminal window.
        case "class", "class-extension", "property", "contents", "type", "record-type", "value-type":
            let codeText = node.attr("code")
            let termName = node.attr("name")
            if !codeText.isEmpty, !termName.isEmpty, let code = try? Code4(parsing: codeText) {
                if dictionary.terms[code] == nil {
                    dictionary.terms[code] = termName
                }
                // A class has a plural name: the one it gives, or its
                // name with an "s". A property can have the code and
                // the name of a class, and come before it: `container`.
                if node.name == "class", dictionary.terms[code] == termName, dictionary.plurals[code] == nil {
                    let plural = node.attr("plural")
                    dictionary.plurals[code] = plural.isEmpty ? termName + "s" : plural
                }
                // Another code for the same word: `<synonym code="dtpQ"/>`.
                for child in node.nodes where child.name == "synonym" && child.attr("name").isEmpty {
                    guard
                        let other = try? Code4(parsing: child.attr("code")),
                        dictionary.terms[other] == nil
                    else {
                        continue
                    }
                    dictionary.terms[other] = termName
                }
            }
        case "enumerator":
            let codeText = node.attr("code")
            let enumName = node.attr("name")
            if !codeText.isEmpty, !enumName.isEmpty, let code = try? Code4(parsing: codeText), dictionary.enums[code] == nil {
                dictionary.enums[code] = enumName
            }
        case "enumeration":
            let groupText = node.attr("code")
            if !groupText.isEmpty {
                for child in node.nodes {
                    let memberText = child.attr("code")
                    let enumName = child.attr("name")
                    if child.name != "enumerator" || memberText.isEmpty || enumName.isEmpty {
                        continue
                    }
                    if let code = try? EventCode(parsing: groupText + memberText) {
                        dictionary.constants[code] = enumName
                    }
                }
            }
        default:
            break
        }
        for child in node.nodes {
            try walk(child)
        }
    }

    do {
        try walk(builder.root!)
    } catch {
        throw ScriptError("parse \(name) terminology: \(error.message)")
    }
    return (dictionary, includes)
}
