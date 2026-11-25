import Extensions
import Foundation
import Terminology

/**
 The entry point libFuzzer calls for the second target: the readers of
 terminology files.

 `osatool learn` reads files that the user names, and they can come
 from anywhere: the definitions inside an application, or a terminology
 file that was saved before. Each input is given to every reader:

 ```
 input ─┬─ TerminologyStore        a saved file: JSON, compact JSON, or a zlib stream
        ├─ parseLanguageDefinition  the language file
        ├─ parseSDEF                an XML scripting definition
        └─ parseScriptSuite         the older pair of property lists
 ```

 A store that is read is written again in its three forms and read
 back, and its dictionaries are added to a registry, as `decompile`
 does with a saved file. The registry is then asked for the words
 inside a `tell` block for each application, and for those of a script
 with a `use application` line for each one, with and without the
 scripting additions.

 The files that a definition includes are not read, but the path of
 each one is worked out, as `learn` does before it reads one.

 An input a reader rejects with an error is fine. Only a crash, a run
 that takes too long, or too much memory is a finding.

 The readers use Foundation, whose objects are freed when an
 autorelease pool ends. libFuzzer calls this function millions of times
 from one loop with no pool, so each call has its own: without it the
 memory only grows, and libFuzzer reports it as a finding.
 */
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzTerminologyInput(_ start: UnsafePointer<UInt8>?, _ count: Int) -> CInt {
    let input = if let start, count > 0 {
        Data(bytes: start, count: count)
    } else {
        Data()
    }
    autoreleasepool { readTerminology(input) }
    return 0
}

/** Gives one input to every reader. */
private func readTerminology(_ input: Data) {
    if let store = try? TerminologyStore(data: input) {
        let readable = store.data()
        let compact = store.data(compact: true)
        // What the tool wrote, the tool reads: a failure here is a finding.
        guard
            let again = try? TerminologyStore(data: compact),
            again.data() == readable,
            let stream = try? compact.zlibCompressed(),
            (try? TerminologyStore(data: stream))?.data() == readable
        else {
            fatalError("a store that was read is not read back the same")
        }
        var registry = Registry()
        var applications: [ApplicationName] = []
        for dictionary in store.dictionaries {
            registry.add(dictionary)
            applications.append(.name(dictionary.name))
            applications.append(.identifier(dictionary.bundleID))
        }
        // Added a second time: a dictionary whose name is there already only fills what has no word.
        for dictionary in store.dictionaries {
            registry.add(dictionary)
        }
        for application in applications {
            _ = registry.scoped(to: application)
        }
        _ = registry.using(applications)
        _ = registry.using(applications, scriptingAdditions: false)
    }
    _ = try? parseLanguageDefinition(input)
    if let definition = try? parseSDEFDocument(name: "fuzz", data: input) {
        for href in definition.includes {
            _ = href.includedDefinitionPath(from: "/tmp/fuzz.sdef")
        }
    }
    _ = try? parseScriptSuite(name: "fuzz", suite: input, terminology: input)
}
