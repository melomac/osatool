import ArgumentParser
import Extensions
import OSAToolbox

/** The `disassemble` subcommand. */
package struct Disassemble: StreamCommand {
    package static let configuration = CommandConfiguration(
        abstract: "Print the bytecode of a compiled script.",
        discussion: copyright,
    )

    @Flag(help: "Treat recovery diagnostics as fatal.")
    var strict = false

    @Flag(help: "Write versioned JSON.")
    var json = false

    @Flag(name: .customLong("builtin-terminology"), help: "Use only the built-in terminology, not what 'learn' saved.")
    var builtinTerminology = false

    @ArgumentParser.Argument(help: "The compiled script (.scpt, .scptd or .app), or - for standard input.", completion: .file())
    var file: String

    package init() {}

    package func run(_ streams: Streams) -> Int32 {
        do {
            let input = try streams.input(at: self.file)
            var options = DisassembleOptions(strict: strict)
            options.terminology = try streams.terminology(builtInOnly: self.builtinTerminology)
            let result = try disassemble(input, options: options)
            for diagnostic in result.diagnostics {
                streams.writeError(diagnostic.description + "\n")
            }
            if self.strict, !result.diagnostics.isEmpty {
                return Status.failure
            }
            streams.writeOutput(self.json ? result.json() : result.text())
            return Status.success
        } catch {
            streams.writeError(error.message + "\n")
            return Status.failure
        }
    }
}
