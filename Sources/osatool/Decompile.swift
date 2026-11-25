import ArgumentParser
import Extensions
import Foundation
import OSAToolbox

/**
 The `decompile` subcommand.

 A JavaScript for Automation (JXA) script holds its source text, which
 is printed as it is: the options do nothing for it.
 */
package struct Decompile: StreamCommand {
    package static let configuration = CommandConfiguration(
        abstract: "Print a compiled script as AppleScript source, or the JavaScript source a JXA script holds.",
        discussion: copyright,
    )

    @Flag(help: "Treat recovery diagnostics as fatal.")
    var strict = false

    @Flag(name: .customLong("no-unwrap"), help: "Do not unwrap embedded compiled scripts.")
    var noUnwrap = false

    @Option(
        name: .customLong("pass"), parsing: .singleValue, help: "Apply an AST pass (repeatable: strings).",
        completion: .list(DecompilePass.allCases.map(\.rawValue)),
    )
    var passNames: [String] = []

    @Flag(name: .customLong("builtin-terminology"), help: "Use only the built-in terminology, not what 'learn' saved.")
    var builtinTerminology = false

    @ArgumentParser.Argument(help: "The compiled script (.scpt, .scptd or .app), or - for standard input.", completion: .file())
    var file: String

    package init() {}

    package func validate() throws {
        for name in self.passNames where DecompilePass(rawValue: name) == nil {
            throw ValidationError("unknown pass \(name.quoted)")
        }
    }

    package func run(_ streams: Streams) -> Int32 {
        do {
            let input = try streams.input(at: self.file)
            var options = DecompileOptions(strict: strict, disableEmbeddedUnwrap: noUnwrap)
            options.terminology = try streams.terminology(builtInOnly: self.builtinTerminology)
            options.passes = self.passNames.compactMap { DecompilePass(rawValue: $0) }
            let result = try decompile(input, options: options)
            for diagnostic in result.diagnostics {
                streams.writeError(diagnostic.description + "\n")
            }
            streams.writeOutput(result.source)
            return Status.success
        } catch {
            streams.writeError(error.message + "\n")
            return Status.failure
        }
    }
}
