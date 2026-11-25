/**
 The error thrown when a compiled script cannot be read or processed.

 It carries one message that says what is wrong and, when it is known,
 where: for example `read object header at 0x2c: unexpected end of data`.
 */
package struct ScriptError: Error, CustomStringConvertible, Sendable {
    package let message: String

    package init(_ message: String) {
        self.message = message
    }

    package var description: String {
        self.message
    }
}

package extension Error {
    /**
     A one-line text for any error: the message of a `ScriptError`, or
     the Swift description of another error.
     */
    var message: String {
        (self as? ScriptError)?.message ?? String(describing: self)
    }
}
