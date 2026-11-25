@testable import AST
import Extensions
import Terminology
import Testing

/** Returns a formatter that uses the bundled terminology. */
func contractFormatter() throws -> SourceFormatter {
    try SourceFormatter(terms: Registry.default())
}
