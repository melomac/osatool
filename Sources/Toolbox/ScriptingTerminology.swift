import Extensions
import Foundation
import Terminology

/**
 The dictionaries that turn the codes of a compiled script into words.

 A compiled script stores four-character codes, not words: `'pnam'`,
 not `name`. A code keeps the first word it gets, so what is added
 later never replaces a word that is already known.

 A word is printed only where the compiler knows it. The words of the
 language and of scripting additions are known everywhere in a script.
 The words of an application are known inside a `tell` block for it,
 and in a script with a `use application` line for it. Anywhere else
 its codes are printed raw, like `«class brow»`.

 ```swift
 var terminology = try ScriptingTerminology.builtIn()
 try terminology.add(contentsOf: savedFile)              // written by `osatool learn`
 let problems = terminology.learn(from: ["/Applications/Thing.app"])

 var options = DecompileOptions()
 options.terminology = terminology
 ```
 */
public struct ScriptingTerminology: Sendable {
    /** The dictionaries, as the inner targets use them. */
    package var registry: Registry

    package init(_ registry: Registry) {
        self.registry = registry
    }

    /**
     The terminology inside the program: the AppleScript language,
     Standard Additions, and well-known Apple software.

     - Throws: when the program was linked without its terminology.
     */
    public static func builtIn() throws -> ScriptingTerminology {
        try ScriptingTerminology(Registry.default())
    }

    /** The names of the dictionaries, sorted. */
    public var dictionaryNames: [String] {
        self.registry.dictionaries.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /**
     Adds the dictionaries of a terminology file: what `osatool learn`
     writes, in any of its forms (readable, compact, compressed).

     - Throws: when the data is not such a file. Nothing is added then.
     */
    public mutating func add(_ saved: Data) throws {
        for dictionary in try TerminologyStore(data: saved).dictionaries {
            self.registry.add(dictionary)
        }
    }

    /**
     Adds the dictionaries of a terminology file.

     - Throws: when the file cannot be read, or is not a terminology file.
     */
    public mutating func add(contentsOf file: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ScriptError("read \(file.path): \(error.localizedDescription)")
        }
        try self.add(data)
    }

    /**
     Reads the scripting definitions of applications and adds them.

     A path is an application, a folder (searched to any depth), or one
     definition file: `.sdef`, or the older pair `.scriptSuite` and
     `.scriptTerminology`.

     - Returns: one line for each file that could not be read.
     */
    @discardableResult
    public mutating func learn(from paths: [String]) -> [String] {
        let scan = scanTerminology(paths: paths)
        for dictionary in scan.dictionaries {
            self.registry.add(dictionary)
        }
        return scan.problems
    }
}
