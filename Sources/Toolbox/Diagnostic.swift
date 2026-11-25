import Extensions
import FAS
import Foundation

/**
 A problem the tool recovered from. A problem that stops the work is
 thrown as an error instead.

 What the two positions mean depends on the step that reports:

 ```
 stage       function                   offset
 parse       none                       a position in the file
 decode      the slot of the function   a position in its bytecode
 decompile   the slot of the function   a position in its bytecode, when
                                        one instruction is the cause
 transform   the slot of the function   the position of the node
 ```
 */
public struct Diagnostic: CustomStringConvertible, Sendable {
    /** The step of the work that reported a diagnostic. */
    public enum Stage: String, Sendable {
        /** Reading the file. */
        case parse
        /** Reading the instructions of a function. */
        case decode
        /** Building the syntax tree. */
        case decompile
        /** A pass on the syntax tree. */
        case transform
    }

    public var stage: Stage
    public var function: Int?
    public var offset: Int?
    /** The opcode byte, when the problem is about one instruction. */
    public var opcode: UInt8?
    public var message: String

    public init(stage: Stage, function: Int? = nil, offset: Int? = nil, opcode: UInt8? = nil, message: String) {
        self.stage = stage
        self.function = function
        self.offset = offset
        self.opcode = opcode
        self.message = message
    }

    /** One line of text: `stage at 0xoffset: message`, or `stage: message`. */
    public var description: String {
        let location = self.offset.map { " at 0x" + $0.hex } ?? ""
        return "\(self.stage.rawValue)\(location): \(self.message)"
    }
}

extension Diagnostic {
    /** Copies a diagnostic of the inner targets, which have their own type. */
    init(_ inner: Extensions.Diagnostic) {
        let stage: Stage = switch inner.stage {
        case .parse: .parse
        case .decode: .decode
        case .decompile: .decompile
        case .transform: .transform
        }
        self.init(stage: stage, function: inner.function, offset: inner.offset, opcode: inner.opcode, message: inner.message)
    }
}

/**
 Upper bounds that protect the tool against damaged or hostile files.
 A value of zero (or less) means "use the default": see `defaults()`.

 ```
 maxInputBytes    the size of the file                        64 MB
 maxObjects       the number of objects in the file           1048576
 maxReferences    the number of references between objects    1048576
 maxDepth         how deep objects are inside one another     1024
 maxBlobBytes     the size of one block of data               64 MB
 ```
 */
public struct Limits: Sendable {
    public var maxInputBytes: Int
    public var maxObjects: Int
    public var maxReferences: Int
    public var maxDepth: Int
    public var maxBlobBytes: Int

    public init(maxInputBytes: Int = 0, maxObjects: Int = 0, maxReferences: Int = 0, maxDepth: Int = 0, maxBlobBytes: Int = 0) {
        self.maxInputBytes = maxInputBytes
        self.maxObjects = maxObjects
        self.maxReferences = maxReferences
        self.maxDepth = maxDepth
        self.maxBlobBytes = maxBlobBytes
    }

    /** The bounds used for a value of zero. */
    public static func defaults() -> Limits {
        let limits = FAS.Limits.defaults()
        return Limits(
            maxInputBytes: limits.maxInputBytes, maxObjects: limits.maxObjects, maxReferences: limits.maxReferences,
            maxDepth: limits.maxDepth, maxBlobBytes: limits.maxBlobBytes,
        )
    }

    /** The same bounds, for the parser. */
    var parseLimits: FAS.Limits {
        FAS.Limits(
            maxInputBytes: self.maxInputBytes, maxObjects: self.maxObjects, maxReferences: self.maxReferences,
            maxDepth: self.maxDepth, maxBlobBytes: self.maxBlobBytes,
        )
    }
}

/**
 The error of the inner targets says what is wrong in one line. With
 this, `localizedDescription` gives that line to a program that only
 sees `any Error`.
 */
extension ScriptError: LocalizedError {
    package var errorDescription: String? {
        self.message
    }
}
