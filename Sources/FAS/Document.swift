import Extensions

/** Upper bounds that protect the tool against damaged or hostile files. */
package struct Limits: Sendable {
    package var maxInputBytes: Int
    package var maxObjects: Int
    package var maxReferences: Int
    package var maxDepth: Int
    package var maxBlobBytes: Int

    /** A value of zero (or less) means "use the default". */
    package init(maxInputBytes: Int = 0, maxObjects: Int = 0, maxReferences: Int = 0, maxDepth: Int = 0, maxBlobBytes: Int = 0) {
        self.maxInputBytes = maxInputBytes
        self.maxObjects = maxObjects
        self.maxReferences = maxReferences
        self.maxDepth = maxDepth
        self.maxBlobBytes = maxBlobBytes
    }

    package static func defaults() -> Limits {
        Limits(
            maxInputBytes: 64 << 20,
            maxObjects: 1 << 20,
            maxReferences: 1 << 20,
            maxDepth: 1024,
            maxBlobBytes: 64 << 20,
        )
    }
}

/** How `parse` reads a file. */
package struct ParseOptions {
    /** When true, a problem the parser could recover from is an error. */
    package var strict: Bool
    package var limits: Limits

    package init(strict: Bool = false, limits: Limits = Limits()) {
        self.strict = strict
        self.limits = limits
    }
}

package final class Document {
    /** The four version bytes, for example `1.10`. */
    package var version: [UInt8]
    package var root: Value
    package var diagnostics: [Diagnostic]

    package init(version: [UInt8] = [0, 0, 0, 0], root: Value = .null, diagnostics: [Diagnostic] = []) {
        self.version = version
        self.root = root
        self.diagnostics = diagnostics
    }
}
