import Extensions
import Terminology

/** The names that `SourceFormatter.name` notes while a script is printed: see `SourceFormatter.script`. */
final class NameNotes {
    var names: Set<String> = []
}

/**
 Prints a syntax tree as AppleScript source text.

 `terms` is used to turn codes into words. Without it, codes are printed
 in their raw form, for example `«class pnam»`.

 The printer is in several files, one for each part of the language:

 ```
 Format.swift              a script, its members, a script object
 FormatHandlers.swift      the header of a handler
 FormatStatements.swift    statements and blocks
 FormatExpressions.swift   values and operators
 Precedence.swift          where parentheses are needed
 FormatCalls.swift         calls to commands and to handlers
 FormatSpecifiers.swift    object specifiers: `item 1 of x`
 FormatText.swift          strings, names and raw codes
 ```
 */
package struct SourceFormatter {
    /**
     The words known where the printer is: those of the language and of
     scripting additions, and inside a `tell` block those of the
     application (see `inside(_:)`).
     */
    package var terms: Registry?
    /** The words outside every `tell` block, once a block is entered. */
    var allTerms: Registry?
    /** True inside `using terms from`: a command of the application can be named with its words. */
    var usingTerms = false

    /**
     True while the statements of a `repeat with` loop are printed.
     There, Apple's tools put every call written with colons in
     parentheses: `(a's addObject:i)`.
     */
    var insideRepeatWith = false

    /** True in the copy that prints a piece again with every name of `joiningWords` between bars: see `before`. */
    var barsJoiningNames = false
    /** The names that have bars everywhere in the script: see `script`. */
    var barredNames: Set<String> = []
    /** Where `name` notes the names for `barredNames`, while a script is printed the first time. */
    var notes: NameNotes?

    package init(terms: Registry? = nil) {
        self.terms = terms
    }

    /**
     Prints a whole script: its members, in order. The words of an
     application named by a `use` line are known in all of it.

     A name that is a word of an application has bars only inside the
     `tell` block of that application. With a capital letter that is two
     variables for the compiler: `Subject` and `|Subject|`. So the
     script is printed once to find these names (see `name`), and once
     more with bars around them everywhere.
     */
    package func script(_ script: Script) -> String {
        var whole = self
        whole.terms = self.terms?.using(script.uses.compactMap(\.applicationName), scriptingAdditions: script.uses.loadScriptingAdditions)
        let notes = NameNotes()
        whole.notes = notes
        let text = whole.members(script.members, 0).joined(separator: "\n\n") + "\n"
        if notes.names.isEmpty {
            return text
        }
        whole.notes = nil
        whole.barredNames = notes.names
        return whole.members(script.members, 0).joined(separator: "\n\n") + "\n"
    }

    /**
     Prints a name of the user: a variable, a handler, a label. A word
     that the language or Standard Additions uses is written between
     bars, like any text that is not a plain word: `|count|`, `|my name|`.
     */
    func name(_ text: String) -> String {
        let plain = text.identifier
        guard plain == text else {
            return plain
        }
        let hasCapital = text != text.lowercased()
        let joins = joiningWords[text.lowercased()] != nil
        if self.terms?.isScriptWord(text) == true {
            // A word of the application of this `tell` block only.
            if hasCapital, let all = self.allTerms, !all.isScriptWord(text) {
                self.notes?.names.insert(text)
            }
            return "|" + text + "|"
        }
        // The compiler takes `Start` and `|Start|` for two variables
        // when the name has a capital letter. So a name like that has
        // bars everywhere when it has bars somewhere: in front of `with`
        // (see `before`), or in a `tell` block (see `script`).
        if hasCapital, joins || self.barredNames.contains(text) {
            return "|" + text + "|"
        }
        return self.barsJoiningNames && joins ? "|" + text + "|" : plain
    }

    /**
     Returns `text` as it must be written in front of `next`, the word
     that follows it on the line.

     A few keywords are two words, and the first one alone is a plain
     name: `start with`, `contained by` (see `joiningWords`). A name
     like that needs no bars, except in front of the second word:

     ```
     display dialog start                     a variable
     display dialog |start| with icon 1       not `start with`
     repeat with i from 1 to |contained| by 2
     ```

     Only a name gets bars, not the last word of a term such as
     `arrow at start`: between bars it would be a name of the user.
     `barred` tells them apart. It is the same text, printed by
     `barring`: it ends with the word between bars when the word is a
     name.
     */
    func before(_ text: String, _ next: String, barred: @autoclosure () -> String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = scalars.count
        while start > 0, scalars[start - 1].isLetter || scalars[start - 1].isDecimalDigit || scalars[start - 1] == "_" {
            start -= 1
        }
        var word = String.UnicodeScalarView()
        word.append(contentsOf: scalars[start...])
        let last = String(word)
        guard
            let seconds = joiningWords[last.lowercased()],
            let second = next.split(separator: " ").first,
            seconds.contains(second.lowercased()),
            barred().hasSuffix("|" + last + "|")
        else {
            return text
        }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars[..<start])
        return String(kept) + "|" + last + "|"
    }

    /** A copy of the printer that writes every name of `joiningWords` between bars: see `before`. */
    var barring: SourceFormatter {
        var copy = self
        copy.barsJoiningNames = true
        return copy
    }

    /**
     Joins the parts of a line with a space, each one written as it must
     be in front of the next (see `before`). `barred` is the same parts,
     printed by `barring`.
     */
    func parts(_ parts: [String], barred: @autoclosure () -> [String]) -> String {
        var printed: [String]?
        func barredPart(_ index: Int) -> String {
            let all = printed ?? barred()
            printed = all
            return index < all.count ? all[index] : parts[index]
        }
        var line = ""
        for (index, part) in parts.enumerated() {
            let next = index + 1 < parts.count ? parts[index + 1] : ""
            line += (index > 0 ? " " : "") + self.before(part, next, barred: barredPart(index))
        }
        return line
    }

    /** The spaces in front of a line that is `indent` blocks deep. */
    func margin(_ indent: Int) -> String {
        String(repeating: "    ", count: indent)
    }

    /**
     Prints the members of a script or of a script object, as blocks.
     The caller puts one empty line between two blocks.

     `use` lines and properties that follow each other are one block.
     A script object or a handler is a block of its own. The statements
     of an implicit run handler are a block too, with no `on run` line.
     */
    func members(_ members: [Member], _ indent: Int) -> [String] {
        let prefix = self.margin(indent)
        var blocks: [String] = []
        var lines: [String] = []
        /** Ends the block of `use` lines and properties, when there is one. */
        func endLines() {
            if !lines.isEmpty {
                blocks.append(lines.joined(separator: "\n"))
                lines = []
            }
        }
        for member in members {
            switch member {
            case let .use(use):
                lines.append(prefix + self.use(use))
            case let .globals(declaration):
                lines.append(prefix + self.line(declaration))
            case let .property(property):
                lines.append(prefix + "property " + self.propertyName(property) + " : " + self.expr(property.value))
            case let .object(object):
                endLines()
                blocks.append(self.scriptObject(object, indent))
            case let .handler(handler):
                endLines()
                if !handler.isImplicit {
                    blocks.append(self.handlerBlock(handler, indent))
                } else if !handler.body.isEmpty {
                    blocks.append(String(self.statements(handler.body, indent).dropLast()))
                }
            }
        }
        endLines()
        return blocks
    }

    /**
     Prints a `use` line:

     ```
     use AppleScript version "2.4"
     use application "Finder"
     use application id "com.apple.finder"
     use framework "Foundation"
     use scripting additions
     use tools : script "Tools"
     use script "Tools"
     ```
     */
    func use(_ use: Use) -> String {
        if use.version {
            "use AppleScript version " + use.name.stringLiteral
        } else if use.application {
            "use application " + (use.isIdentifier ? "id " : "") + use.name.stringLiteral
        } else if use.framework {
            "use framework " + use.name.stringLiteral
        } else if use.scriptingAdditions {
            "use scripting additions"
        } else if !use.alias.isEmpty {
            "use " + self.name(use.alias) + " : script " + use.name.stringLiteral
        } else {
            "use script " + use.name.stringLiteral
        }
    }

    /** Prints the name of a property: a user word, or a word given by its code. */
    func propertyName(_ property: Property) -> String {
        if let keyword = property.keyword {
            return self.expr(keyword)
        }
        return self.name(property.name)
    }

    /** Prints a script object, from `script name` to `end script`. */
    func scriptObject(_ node: ScriptObject, _ indent: Int) -> String {
        let prefix = self.margin(indent)
        let blocks = self.members(node.members, indent + 1)
        let body = blocks.isEmpty ? "" : blocks.joined(separator: "\n\n") + "\n"
        // A script object made in a handler can have no name.
        let header = node.name.isEmpty ? "script" : "script " + self.name(node.name)
        return prefix + header + "\n" + body + prefix + "end script"
    }
}

/** Prints a script as AppleScript source text. See `SourceFormatter`. */
package func format(_ script: Script, terms: Registry?) -> String {
    SourceFormatter(terms: terms).script(script)
}
