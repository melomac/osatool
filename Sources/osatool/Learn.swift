import ArgumentParser
import Extensions
import Foundation
import Terminology

/**
 The `learn` subcommand: reads the scripting definitions of applications
 and saves their terms for later runs of `decompile`.

 ```
 osatool learn /Applications          every application in the folder
 osatool learn ~/Apps/Thing.app       one application
 osatool learn Thing.sdef             one definition file
 ```

 What is learned goes to the user's terminology file. An application that
 was learned before is replaced by its new scan; the others stay.

 With `--output`, the terms go to that file only and the user's file is
 not changed. The built-in terminology of the tool is made this way.

 A file written before can be given like an application: its
 dictionaries are taken as they are. So a file can be written again in
 another form:

 ```
 osatool learn --compact --compress --output small.bin terminology.json
 ```
 */
package struct Learn: StreamCommand {
    package static let configuration = CommandConfiguration(
        abstract: "Read the scripting definitions of applications and remember their terms.",
        discussion: """
        Folders are searched to any depth for .sdef files and for pairs of \
        .scriptSuite and .scriptTerminology files. The terms are saved, and \
        'decompile' then uses them for the codes it does not know.

        \(copyright)
        """,
    )

    @Option(
        name: .shortAndLong, help: "Write the terms to this file, and leave the saved terminology as it is.",
        completion: .file(),
    )
    var output: String?

    @Flag(help: "Write the JSON on one line, without spaces.")
    var compact = false

    @Flag(help: "Compress the file (a zlib stream). The tool reads it like any other.")
    var compress = false

    @ArgumentParser.Argument(
        help: "Applications, folders, definition files, or files written by this command.",
        completion: .file(),
    )
    var paths: [String]

    package init() {}

    package func run(_ streams: Streams) -> Int32 {
        let scan = scanTerminology(paths: self.paths)
        for problem in scan.problems {
            streams.writeError(problem + "\n")
        }
        if scan.dictionaries.isEmpty {
            streams.writeError("no scripting definition found\n")
            return Status.failure
        }
        do {
            var store = TerminologyStore()
            let destination: URL
            if let output {
                destination = URL(fileURLWithPath: output)
            } else if let url = streams.learnedTerminology {
                destination = url
                if let saved = try? Data(contentsOf: url) {
                    store = try TerminologyStore(data: saved)
                }
            } else {
                throw ScriptError("there is no place to save the terminology; use --output")
            }
            store.system = ProcessInfo.processInfo.operatingSystemVersionString
            store.replace(with: scan.dictionaries)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = store.data(compact: self.compact)
            try (self.compress ? text.zlibCompressed() : text).write(to: destination, options: .atomic)
            for dictionary in scan.dictionaries {
                streams.writeOutput(
                    "\(dictionary.name): \(dictionary.commands.count) commands, \(dictionary.terms.count) terms, "
                        + "\(dictionary.enums.count) enumerators\n",
                )
            }
            streams.writeOutput("\(store.dictionaries.count) dictionaries saved in \(destination.path)\n")
            return Status.success
        } catch {
            streams.writeError(error.message + "\n")
            return Status.failure
        }
    }
}
