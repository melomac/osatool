import Extensions

/** The decoded instructions of one function. */
package struct DecodedFunction {
    package var offset: Int
    package var instructions: [Instruction] = []
    package var diagnostics: [Diagnostic] = []
    /** True when the code has more instructions than the caller asked for: the rest was not read. */
    package var isCut = false

    package init(offset: Int) {
        self.offset = offset
    }
}

/**
 Reads the operand words of one instruction from the bytecode.

 Each operand is a signed 16-bit big-endian word. A branch operand is a
 distance, counted from the position of the word itself:

 ```
 offset   0x10   0x11  0x12
          opcode   00    05        the branch leads to 0x11 + 5 = 0x16
 ```

 When the code ends before a word, the word is counted in `missing` and
 its value is 0.
 */
struct CodeReader: OperandSource {
    let code: [UInt8]
    /** The position of the next byte to read. */
    var position: Int
    /** The number of words that were asked for after the end of the code. */
    var missing = 0

    mutating func word() -> Int {
        self.next() ?? 0
    }

    mutating func target() -> Int {
        let base = self.position
        return self.next().map { base + $0 } ?? 0
    }

    private mutating func next() -> Int? {
        guard
            self.missing == 0,
            self.position + 2 <= self.code.count
        else {
            self.missing += 1
            return nil
        }
        defer { self.position += 2 }
        return Int(Int16(bitPattern: UInt16(self.code[self.position]) << 8 | UInt16(self.code[self.position + 1])))
    }
}

/**
 Decodes the bytecode of one function into instructions.

 An instruction is one opcode byte, followed by zero, one or two operands.
 Each operand is a signed 16-bit big-endian word:

 ```
 +--------+-----------------+-----------------+
 | opcode | operand (2 B)   | operand (2 B)   |
 +--------+-----------------+-----------------+
 ```

 Opcodes from 160 to 255 have no operand bytes: their index is the low
 4 bits of the opcode itself.

 A branch operand is a distance. It is counted from the position of the
 operand word, and stored here as an absolute target offset.

 - Parameters:
   - functionOffset: the slot of the function in its table (kept as is).
   - code: the bytecode.
   - strict: when true, a cut-off operand throws. When false, the broken
     instruction is kept with the bytes that are left, and decoding stops.
   - limit: the number of instructions to read at most. When the code
     has more, the result has `isCut` set. An instruction takes far more
     memory than its bytes, so a caller that reads a file anyone could
     have made gives a limit.
 */
package func decode(_ functionOffset: Int, _ code: [UInt8], strict: Bool, limit: Int = .max) throws -> DecodedFunction {
    var out = DecodedFunction(offset: functionOffset)
    var position = 0
    while position < code.count {
        if out.instructions.count >= limit {
            out.isCut = true
            break
        }
        let start = position
        let byte = code[start]
        var reader = CodeReader(code: code, position: start + 1)
        var instruction = Instruction(offset: start, byte: byte, opcode: Opcode(byte: byte, operands: &reader))

        if reader.missing > 0 {
            let error = ScriptError("truncated operand for \(instruction.mnemonic) at 0x\(start.hex)")
            out.diagnostics.append(Diagnostic(stage: .decode, function: functionOffset, offset: start, opcode: byte, message: error.message))
            if strict {
                throw error
            }
            instruction.missingOperands = reader.missing
            instruction.takeBytes(code, start ..< code.count)
            out.instructions.append(instruction)
            break
        }
        position = reader.position
        instruction.takeBytes(code, start ..< position)
        out.instructions.append(instruction)
    }
    return out
}
