/** The step of the pipeline that reported a diagnostic. */
package enum Stage: String, Sendable {
    case parse
    case decode
    case decompile
    case transform
}

/**
 A problem the tool recovered from. A problem that stops the work is
 thrown as a `ScriptError` instead.

 Every step of the pipeline reports with this one type. What the two
 positions mean depends on the step:

 ```
 stage       function                   offset
 parse       none                       a position in the file
 decode      the slot of the function   a position in its bytecode
 decompile   the slot of the function   a position in its bytecode, when
                                        one instruction is the cause
 transform   the slot of the function   the position of the node
 ```

 - `opcode`: the opcode byte, when the problem is about one instruction.
 */
package struct Diagnostic: CustomStringConvertible, Sendable {
    package var stage: Stage
    package var function: Int?
    package var offset: Int?
    package var opcode: UInt8?
    package var message: String

    package init(stage: Stage, function: Int? = nil, offset: Int? = nil, opcode: UInt8? = nil, message: String) {
        self.stage = stage
        self.function = function
        self.offset = offset
        self.opcode = opcode
        self.message = message
    }

    /** One line of text: `stage at 0xoffset: message`, or `stage: message`. */
    package var description: String {
        let location = self.offset.map { " at 0x" + $0.hex } ?? ""
        return "\(self.stage.rawValue)\(location): \(self.message)"
    }
}
