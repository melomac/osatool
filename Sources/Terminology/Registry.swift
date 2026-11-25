import Extensions
import Foundation

/** A named parameter of a command, for example `with prompt`. */
package struct CommandParameter: Sendable {
    package var code: Code4
    package var name: String
    /** The type written in the dictionary, for example `boolean`. */
    package var type: String

    package init(code: Code4, name: String, type: String = "") {
        self.code = code
        self.name = name
        self.type = type
    }
}

package struct Command: Sendable {
    package var code: EventCode
    package var name: String
    package var parameters: [Code4: CommandParameter]
    /** The parameter codes, in the order the dictionary lists them. */
    package var parameterOrder: [Code4]
    package var hasDirectParameter: Bool

    package init(
        code: EventCode = EventCode(), name: String = "", parameters: [Code4: CommandParameter] = [:],
        parameterOrder: [Code4] = [], hasDirectParameter: Bool = false,
    ) {
        self.code = code
        self.name = name
        self.parameters = parameters
        self.parameterOrder = parameterOrder
        self.hasDirectParameter = hasDirectParameter
    }
}

/**
 The terms of one application, or of the AppleScript language.

 A dictionary maps codes to the words a script author writes:

 ```
 commands    event code (8 bytes)   →  command and its parameters
 terms       code (4 bytes)         →  class, property or type name
 enums       code (4 bytes)         →  enumerator name
 constants   enumeration + member   →  enumerator name
 plurals     code (4 bytes)         →  plural name of a class
 ```
 */
package struct ScriptingDictionary: Sendable {
    package var name: String
    /** The files the terms were read from. */
    package var sources: [String]
    package var commands: [EventCode: Command]
    package var terms: [Code4: String]
    package var enums: [Code4: String]
    package var constants: [EventCode: String]
    /** The plural name of a class: `items` for `item`. A range is written with it. */
    package var plurals: [Code4: String]
    /**
     The words that need bars to be the name of a variable, in lower
     case. Only the language has such a list: it was asked to the compiler.
     */
    package var reservedWords: Set<String> = []
    /**
     The bundle identifier of the application, when it has one:
     `com.apple.finder`. A script can name its target that way:
     `tell application id "com.apple.finder"`.
     */
    package var bundleID = ""

    /**
     True for a scripting addition: a dictionary read from an `.osax`
     bundle, like Standard Additions. A script can use its words
     everywhere, not only inside a `tell` block.

     The innermost bundle around the first file of the dictionary
     decides. An application inside an `.osax` folder is an
     application, and so is one whose definition includes a file of a
     scripting addition.
     */
    package var isScriptingAddition: Bool {
        self.name == standardAdditionsName || (self.sources.first?.owner as NSString?)?.pathExtension == "osax"
    }

    /**
     True for an application that describes itself with script suites
     only (`.scriptSuite` files) and no `.sdef` file. Cocoa then adds
     its own suites to the words of the application: see
     `cocoaSuiteNames`.
     */
    package var usesCocoaSuites: Bool {
        !self.sources.isEmpty && self.sources.allSatisfy { !$0.hasSuffix(".sdef") }
            && self.sources.contains { $0.hasSuffix(".scriptSuite") }
    }

    /** Every word of the dictionary, in lower case: classes, properties, enumerators, plurals and commands. */
    package var words: Set<String> {
        var words = Set(self.terms.values.map { $0.lowercased() })
        words.formUnion(self.enums.values.map { $0.lowercased() })
        words.formUnion(self.constants.values.map { $0.lowercased() })
        words.formUnion(self.plurals.values.map { $0.lowercased() })
        words.formUnion(self.commands.values.map { $0.name.lowercased() })
        return words
    }

    package init(
        name: String, sources: [String] = [], commands: [EventCode: Command] = [:], terms: [Code4: String] = [:],
        enums: [Code4: String] = [:], constants: [EventCode: String] = [:], plurals: [Code4: String] = [:],
    ) {
        self.name = name
        self.sources = sources
        self.commands = commands
        self.terms = terms
        self.enums = enums
        self.constants = constants
        self.plurals = plurals
    }
}

/** How a script names an application whose words it uses. */
package enum ApplicationName: Hashable, Sendable {
    /** `application "Finder"`, or a path that ends with the name. */
    case name(String)
    /** `application id "com.apple.finder"`. */
    case identifier(String)
}

/**
 The dictionaries a script is printed with.

 The compiler does not know every word everywhere, and the registry
 follows it:

 ```
 the language, scripting additions     everywhere in a script
 an application                        only inside a `tell` block for it
 ```

 So a search (`term`, `enumeration`, `command`…) finds the words of
 the language and of scripting additions. `scoped(to:)` gives the
 registry for the inside of a `tell` block, which also finds the words
 of that application. A code that no dictionary in reach has a word
 for is printed in its raw form, like `«class brow»`: that form
 compiles everywhere.

 When two dictionaries in reach define the same code, the one added
 first wins.

 The built-in terminology is added first, and what `learn` saved comes
 after it. A file that `learn` read can be made by anyone, so what comes
 later never takes the place of what is there (see `add`):

 ```
 a dictionary named like one that is there    adds only the codes that had no word
 a name in another letter case (`finder`)     is the same dictionary
 an identifier that a dictionary has already  stays with that dictionary
 ```
 */
package struct Registry: Sendable {
    /** All the dictionaries, by name: also those of applications. */
    package private(set) var dictionaries: [String: ScriptingDictionary] = [:]
    /** The name of each dictionary, by that name in lower case. */
    private var names: [String: String] = [:]
    /** The name of the first dictionary added with each bundle identifier, in lower case. */
    private var identifierOwners: [String: String] = [:]
    /** False in a script that does not load the scripting additions: see `using`. */
    package private(set) var knowsScriptingAdditions = true
    var commands: [EventCode: Command] = [:]
    var terms: [Code4: String] = [:]
    var enums: [Code4: String] = [:]
    var constants: [EventCode: String] = [:]
    var plurals: [Code4: String] = [:]
    var language: ScriptingDictionary?
    var parameters: [Code4: String] = [:]
    /** The single words of the language and of Standard Additions, in lower case. */
    var scriptWords: Set<String> = []

    /** Creates an empty registry. */
    package init() {}

    package func dictionary(_ name: String) -> ScriptingDictionary? {
        self.dictionaries[name]
    }

    /**
     Finds a command by its event code. A few old spellings of an event
     code are also accepted (see `compatibilityEventAliases`).
     */
    package func command(_ code: EventCode) -> Command? {
        if let value = commands[code] {
            return value
        }
        if let canonical = compatibilityEventAliases[code] {
            return self.commands[canonical]
        }
        return nil
    }

    /**
     Finds a command that a script can use outside a `tell` block: a
     command of the AppleScript language, or of Standard Additions.

     `command(_:)` also knows the commands of applications. Their words
     compile only inside `tell` or `using terms from`.
     */
    package func scriptCommand(_ code: EventCode) -> Command? {
        let code = compatibilityEventAliases[code] ?? code
        if let command = self.language?.commands[code] {
            return command
        }
        return self.knowsScriptingAdditions ? self.dictionaries[standardAdditionsName]?.commands[code] : nil
    }

    /**
     Finds a command in any dictionary, also in one of an application,
     wherever the script is. Its words may not compile there: this is
     for a text that is not source, like the name of a handler in a
     listing. With several dictionaries, the first name wins.
     */
    package func commandAnywhere(_ code: EventCode) -> Command? {
        if let command = self.command(code) {
            return command
        }
        let code = compatibilityEventAliases[code] ?? code
        for name in self.dictionaries.keys.sorted() {
            if let command = self.dictionaries[name]?.commands[code] {
                return command
            }
        }
        return nil
    }

    package func term(_ code: Code4) -> String? {
        self.terms[code]
    }

    package func enumeration(_ code: Code4) -> String? {
        self.enums[code]
    }

    package func constant(_ code: EventCode) -> String? {
        self.constants[code]
    }

    /**
     Returns the plural name of a class, when it is known and when the
     class is known by the name it is the plural of.
     */
    package func plural(_ code: Code4) -> String? {
        self.plurals[code]
    }

    /**
     True for a class whose name is also its plural: `text` in the
     language, `rich text` in Mail. The compiler reads `text of x` as
     `every text of x`, so the printer can leave `every` out.
     */
    package func isOwnPlural(_ code: Code4) -> Bool {
        guard let name = self.terms[code] else {
            return false
        }
        if self.language?.terms[code] == name {
            return languageOwnPlurals.contains(code)
        }
        return self.plurals[code] == name
    }

    /** Finds a term in the AppleScript language only, not in applications. */
    package func languageTerm(_ code: Code4) -> String? {
        self.language?.terms[code]
    }

    /** Finds an enumerator in the AppleScript language only. */
    package func languageEnumeration(_ code: Code4) -> String? {
        self.language?.enums[code]
    }

    /**
     Returns the registry to use inside `tell application "name"`: the
     words of that application are known there, and they come before
     the others.

     ```
     tell application "Finder"            tell application "System Events"
         home                                 home directory of current user
         Finder window 1                      «class brow» 1
     ```

     `home` and `home directory` have the same code. Only Finder has a
     word for `«class brow»`.

     Call it on the registry of the whole script, not on one that is
     scoped already: a `tell` inside another `tell` knows the words of
     its own application only, as the compiler does.

     - `application`: a name (`Finder`), or a path that ends with one
       (`/System/Library/CoreServices/Finder.app`).
     - Returns: this registry when no dictionary has that name.
     */
    package func scoped(to application: String) -> Registry {
        self.scoped(to: .name(application))
    }

    /**
     Returns the registry to use inside `tell application id "…"`. The
     case of the letters does not matter.

     - Returns: this registry when no dictionary has that identifier.
     */
    package func scoped(toID identifier: String) -> Registry {
        self.scoped(to: .identifier(identifier))
    }

    /**
     Returns the registry to use inside a `tell` block for this
     application: see `scoped(to:)`.

     An application that no dictionary describes still has the words
     the system adds to an application (see
     `intrinsicsDictionaryName`): `properties of window 1`.
     */
    package func scoped(to application: ApplicationName) -> Registry {
        if let dictionary = self.words(of: application) ?? self.dictionaries[intrinsicsDictionaryName] {
            return self.scoped(with: dictionary)
        }
        return self
    }

    /**
     Returns the registry for a whole script with `use application`
     lines. The words of these applications are known everywhere in the
     script, and the application of the first line comes first:

     ```
     use application "Finder"
     set x to name of Finder window 1
     ```

     A word that two of these applications have is not known, unless
     the language has it too: the compiler refuses it as ambiguous. It
     is known again inside a `tell` block for an application that has
     it.

     ```
     use application "Finder"
     use application "System Events"
     set x to «class cfol» 1            `folder` is a word of both
     tell application "Finder" to set y to folder 1
     ```

     A script with a `use` line loads the scripting additions only when
     it says so. Without `use scripting additions` their words do not
     compile, anywhere in the script, and the code is what is left to
     write:

     ```
     use framework "Foundation"
     set x to «event sysoexec» "ls"     `do shell script` is not known
     ```

     - `scriptingAdditions`: false for such a script.
     */
    package func using(_ applications: [ApplicationName], scriptingAdditions: Bool = true) -> Registry {
        (scriptingAdditions ? self : self.withoutScriptingAdditions()).usingApplications(applications)
    }

    /** Returns this registry with the words of the language only, outside a `tell` block. */
    func withoutScriptingAdditions() -> Registry {
        guard
            self.knowsScriptingAdditions,
            let language = self.language
        else {
            return self
        }
        var result = self
        (result.commands, result.terms, result.enums, result.constants) = ([:], [:], [:], [:])
        (result.plurals, result.parameters) = ([:], [:])
        result.addLanguage(language)
        // A word that needs bars with the additions is still written with them: bars compile everywhere.
        result.scriptWords = self.scriptWords
        result.knowsScriptingAdditions = false
        return result
    }

    private func usingApplications(_ applications: [ApplicationName]) -> Registry {
        var used: [ScriptingDictionary] = []
        for application in applications {
            if let dictionary = self.words(of: application), !used.contains(where: { $0.name == dictionary.name }) {
                used.append(dictionary)
            }
        }
        var result = self
        for dictionary in used.reversed() {
            result = result.scoped(with: dictionary)
        }
        guard used.count > 1 else {
            return result
        }
        var owners: [String: Int] = [:]
        for word in used.flatMap(\.words) {
            owners[word, default: 0] += 1
        }
        let ambiguous = Set(owners.filter { $0.value > 1 }.keys).subtracting(self.language?.words ?? [])
        // An ambiguous word gives its place back to the word known without the applications, if any.
        for (code, word) in result.terms where ambiguous.contains(word.lowercased()) {
            result.terms[code] = self.terms[code]
        }
        for (code, word) in result.enums where ambiguous.contains(word.lowercased()) {
            result.enums[code] = self.enums[code]
        }
        for (code, word) in result.constants where ambiguous.contains(word.lowercased()) {
            result.constants[code] = self.constants[code]
        }
        for (code, word) in result.plurals where ambiguous.contains(word.lowercased()) || result.terms[code] == nil {
            result.plurals[code] = self.plurals[code]
        }
        for (code, command) in result.commands where ambiguous.contains(command.name.lowercased()) {
            result.commands[code] = self.commands[code]
        }
        return result
    }

    /**
     Finds the dictionary of an application, with what the system adds
     to it: the suites of Cocoa for an application with script suites
     (see `cocoaSuiteNames`), and for the others the words of
     `Intrinsics.sdef` (see `intrinsicsDictionaryName`).

     - Returns: `nil` when no dictionary has that name or identifier,
       and for a scripting addition or the language: they are not
       applications.
     */
    func words(of application: ApplicationName) -> ScriptingDictionary? {
        var found: ScriptingDictionary?
        switch application {
        case let .name(text):
            var name = text.split(separator: "/").last.map(String.init) ?? text
            if name.lowercased().hasSuffix(".app") {
                name.removeLast(4)
            }
            found = self.dictionaries[name] ?? self.names[name.lowercased()].flatMap { self.dictionaries[$0] }
        case let .identifier(text):
            // The first dictionary added with the identifier: a built-in
            // one comes before anything that was learned.
            found = self.identifierOwners[text.lowercased()].flatMap { self.dictionaries[$0] }
        }
        guard
            var dictionary = found,
            !dictionary.isScriptingAddition,
            dictionary.name != languageDictionaryName
        else {
            return nil
        }
        for name in dictionary.usesCocoaSuites ? cocoaSuiteNames : [intrinsicsDictionaryName] {
            if let added = self.dictionaries[name], added.name != dictionary.name {
                dictionary.merge(added)
            }
        }
        return dictionary
    }

    /** Returns this registry with the words of a dictionary put first. */
    func scoped(with dictionary: ScriptingDictionary) -> Registry {
        var scoped = self
        for (code, command) in dictionary.commands {
            var first = command
            // The parameters another dictionary has for the same command stay known.
            if let known = self.commands[code] {
                for parameter in known.parameterOrder where first.parameters[parameter] == nil {
                    first.parameters[parameter] = known.parameters[parameter]
                    first.parameterOrder.append(parameter)
                }
            }
            scoped.commands[code] = first
        }
        for (code, word) in dictionary.terms {
            if scoped.terms[code] != word {
                // The plural belongs to the word it was the plural of.
                scoped.plurals[code] = nil
            }
            scoped.terms[code] = word
        }
        scoped.enums.merge(dictionary.enums) { _, new in new }
        scoped.constants.merge(dictionary.constants) { _, new in new }
        scoped.plurals.merge(dictionary.plurals) { _, new in new }
        // A name of the user that is a word of the application needs
        // bars there: `|tabs|` inside `tell application "Safari"`.
        let words = Array(dictionary.terms.values) + dictionary.enums.values + dictionary.plurals.values + dictionary.commands.values.map(\.name)
        scoped.scriptWords.formUnion(words.filter { !$0.contains(" ") }.map { $0.lowercased() })
        return scoped
    }

    /**
     Returns the name of the application that has a command, when the
     language and Standard Additions do not have it: `Mail` for
     `perform mail action with messages`. A script can name such a
     command only inside `tell` or `using terms from` for that
     application.

     Only a dictionary read from an application counts, not one of a
     framework. With several, the first name is returned.
     */
    package func application(of code: EventCode) -> String? {
        guard self.scriptCommand(code) == nil else {
            return nil
        }
        return self.dictionaries.keys.sorted().first { name in
            guard
                let dictionary = self.dictionaries[name],
                dictionary.commands[code] != nil
            else {
                return false
            }
            return dictionary.sources.contains { $0.contains(".app/") }
        }
    }

    /**
     True for a word that a script cannot use as a name without bars,
     because the language or Standard Additions gives it a meaning:
     `count`, `name`, `null`. The case of the letters does not matter.

     The list comes from the compiler (see `reserved_words` in
     `language.json`). The words of an application are not in it: they
     have a meaning only inside a `tell` block for that application.
     */
    package func isScriptWord(_ word: String) -> Bool {
        self.scriptWords.contains(word.lowercased())
    }

    /**
     Returns the name of a language parameter without knowing its command.

     This works only when every AppleScript command that uses `code` gives
     it the same name. When the names differ, the result is `nil` and the
     caller must look in the specific `Command`.
     */
    package func parameter(_ code: Code4) -> String? {
        self.parameters[code]
    }

    mutating func addLanguage(_ dictionary: ScriptingDictionary) {
        self.language = dictionary
        var ambiguous: Set<Code4> = []
        for command in dictionary.commands.values {
            for (code, parameter) in command.parameters {
                if let name = parameters[code], name != parameter.name {
                    self.parameters[code] = nil
                    ambiguous.insert(code)
                } else if !ambiguous.contains(code) {
                    self.parameters[code] = parameter.name
                }
            }
        }
        self.dictionaries[dictionary.name] = dictionary
        self.names[dictionary.name.lowercased()] = dictionary.name
        self.addWords(dictionary)
        // For a class of the language, the plural of the language is the
        // right one: `text 1 thru 2`, not `texts 1 thru 2`.
        for (code, plural) in dictionary.plurals where self.terms[code] == dictionary.terms[code] {
            self.plurals[code] = plural
        }
    }

    /**
     Adds a dictionary.

     The words of a scripting addition are known everywhere from then
     on. The words of an application are only kept for `scoped(to:)`.

     A dictionary with the name of one that is there already is added
     to it, whatever the case of the letters. It then gives a word only
     to the codes that had none: not to a code the first dictionary
     defines, and not to a code of the language or of a scripting
     addition. Without this, a file named like a well-known application
     could rename a command of the language inside the `tell` blocks of
     that application:

     ```
     built-in       tell application "Finder" to do shell script "…"
     learned        Finder.app, where `sysoexec` is named `reveal`
     printed        tell application "Finder" to reveal "…"        (before)
     ```

     The same holds for the dictionaries that the system adds to every
     application (see `intrinsicsDictionaryName`, `cocoaSuiteNames`).
     */
    package mutating func add(_ dictionary: ScriptingDictionary) {
        let name = self.names[dictionary.name.lowercased()] ?? dictionary.name
        var added = dictionary
        if self.dictionaries[name] != nil {
            added.removeWords(knownTo: self)
        }
        self.dictionaries[name, default: ScriptingDictionary(name: name)].merge(added)
        self.register(name)
        if dictionary.isScriptingAddition {
            self.addWords(dictionary)
        }
    }

    /** Records the name of a dictionary that was just set, and its bundle identifier when no dictionary has it yet. */
    private mutating func register(_ name: String) {
        self.names[name.lowercased()] = name
        let identifier = self.dictionaries[name]?.bundleID.lowercased() ?? ""
        if !identifier.isEmpty, self.identifierOwners[identifier] == nil {
            self.identifierOwners[identifier] = name
        }
    }

    /** Makes the words of a dictionary known everywhere. Codes that are already known keep their meaning. */
    mutating func addWords(_ dictionary: ScriptingDictionary) {
        if !dictionary.reservedWords.isEmpty {
            self.scriptWords.formUnion(dictionary.reservedWords)
        }
        for (code, command) in dictionary.commands {
            guard var known = self.commands[code] else {
                self.commands[code] = command
                continue
            }
            // The same command with more parameters: `duplicate … with replacing`.
            for parameter in command.parameterOrder where known.parameters[parameter] == nil {
                known.parameters[parameter] = command.parameters[parameter]
                known.parameterOrder.append(parameter)
            }
            self.commands[code] = known
        }
        for (code, name) in dictionary.terms where self.terms[code] == nil {
            terms[code] = name
        }
        for (code, name) in dictionary.enums where self.enums[code] == nil {
            enums[code] = name
        }
        for (code, name) in dictionary.constants where self.constants[code] == nil {
            constants[code] = name
        }
        // A plural is kept only with the name it belongs to: the
        // dictionary that gives the name of a code also gives its plural.
        for (code, name) in dictionary.plurals where self.plurals[code] == nil && self.terms[code] == dictionary.terms[code] {
            plurals[code] = name
        }
    }

    /**
     Returns the registry built from the terminology inside the tool
     (see `BundledTerminology`):

     1. the words of the AppleScript language;
     2. Standard Additions, whose words a script can use everywhere;
     3. the other dictionaries, each for the `tell` blocks of its
        application.

     A code keeps the first name it gets. So outside a `tell` block a
     word of the language is never replaced by the word that Standard
     Additions has for the same code.

     The registry is built once, on first use, and then shared.

     - Throws: when the program has no terminology inside it, or when
       it cannot be read.
     */
    package static func `default`() throws -> Registry {
        try self.cachedDefault.get()
    }

    private static let cachedDefault: Result<Registry, any Error> = Result {
        guard let bundled = BundledTerminology.store else {
            throw ScriptError(
                "this program has no terminology inside it: the section "
                    + "\(BundledTerminology.segment),\(BundledTerminology.section) is missing",
            )
        }
        let dictionaries = try TerminologyStore(data: bundled).dictionaries
        var registry = Registry()
        for dictionary in dictionaries where dictionary.name == languageDictionaryName {
            registry.addLanguage(dictionary)
        }
        for dictionary in dictionaries where dictionary.name == standardAdditionsName {
            registry.add(dictionary)
            // The name a script can use: `tell application "Standard Additions"` is not one, but a search by name is.
            registry.dictionaries["Standard Additions"] = dictionary
            registry.register("Standard Additions")
        }
        for dictionary in dictionaries where dictionary.name != standardAdditionsName && dictionary.name != languageDictionaryName {
            registry.add(dictionary)
        }
        return registry
    }
}

/** The name of the dictionary of Standard Additions. */
package let standardAdditionsName = "StandardAdditions"

/**
 The dictionaries that Cocoa adds to an application that has script
 suites and no `.sdef` file, like TextEdit:

 ```
 Foundation       the standard suite: `make`, `count`, `document`, `window`, `properties`
 AppKit           the text suite: `paragraph`, `word`, `attribute run`
 CocoaStandard    the types for printing: `print settings`, `copies`
 ```

 Cocoa makes the types for printing itself, from no file. The
 standard suite for `.sdef` files has the same ones, and its other
 words are those of the first two.
 */
let cocoaSuiteNames = ["Foundation", "AppKit", "CocoaStandard"]

/**
 The name of the dictionary with the words that the system adds to
 every application that has an `.sdef` file: the file `Intrinsics.sdef`
 of Foundation. It has the properties `class` and `properties`, the
 class `item`, and some types (`specifier`, `any`…). An application
 with script suites gets `properties` from the standard suite of Cocoa.

 So inside a `tell` block for an application, `properties` is a
 property, and outside it is the plural of the class `property`:

 ```
 tell application "Safari" to properties of window 1     «class pALL» of window 1
 properties of x                                         every «class prop» of x
 ```
 */
package let intrinsicsDictionaryName = "Intrinsics"

/**
 Event codes that old scripts spell with different letter case. Each one
 maps to the spelling used by the dictionaries.
 */
let compatibilityEventAliases: [EventCode: EventCode] = ["CoRedelo": "coredelo", "CoRedoex": "coredoex"]
