import Extensions

/**
 How an object specifier chooses its object in a container. Each form
 has its own instruction: the raw value is the byte of that instruction.

 ```
 property    name of x                  whose       every item of x whose …
 every       every item of x            range       items 2 thru 4 of x
 some        some item of x             before      window before window 2
 index       item 3 of x                after       window after window 1
 key         window id 7 of x           beginning   beginning of x
 middle      middle item of x           end         end of x
 ```
 */
package enum SpecifierForm: UInt8, Sendable, CaseIterable {
    case property = 44
    case every
    case some
    case index
    case key
    case whose
    case range
    case before
    case after
    case beginning
    case end
    case middle
}

/**
 An operator that takes two values from the stack and pushes one.

 The opcode bytes 0 to 8 are the comparisons and 30 to 37 are the
 arithmetic operators. A comparison inside a `whose` clause uses the
 same numbers (see `Opcode.makeComp`).
 */
package enum Operator: Sendable {
    case equal, notEqual, greaterThan, greaterThanOrEqual, lessThan, lessThanOrEqual
    case startsWith, endsWith, contains
    case add, subtract, multiply, divide, quotient, remainder, power, concatenate

    private static let comparisons: [Operator] = [
        .equal, .notEqual, .greaterThan, .greaterThanOrEqual, .lessThan, .lessThanOrEqual,
        .startsWith, .endsWith, .contains,
    ]

    private static let arithmetic: [Operator] = [
        .add, .subtract, .multiply, .divide, .quotient, .remainder, .power, .concatenate,
    ]

    /** Returns the operator of an opcode byte, or `nil` for another byte. */
    package init?(byte: UInt8) {
        switch byte {
        case 0 ... 8:
            self = Self.comparisons[Int(byte)]
        case 30 ... 37:
            self = Self.arithmetic[Int(byte) - 30]
        default:
            return nil
        }
    }
}

/**
 Gives the operands of one instruction, in the order they are stored.

 The decoder reads them from the bytecode. A test can give them from a
 list.
 */
package protocol OperandSource {
    /** Returns the next operand word. */
    mutating func word() -> Int

    /**
     Returns the next operand word as the place a branch leads to: an
     offset in the code of the function.
     */
    mutating func target() -> Int
}

/**
 What one instruction does, with its operands.

 The first byte of an instruction selects the case. The 256 values are
 grouped like this:

 ```
   0 –  43   operators and control flow (Equal, Tell, TestIf, …)
  44 –  55   MakeObjectAlias   (object specifiers)
  56 –  68   MakeComp          (comparisons inside `whose`)
  69 – 118   data, blocks, jumps, small constants
 119 – 159   None / Undefined
 160 – 175   PushVariable   index in the low 4 bits
 176 – 191   PopVariable    index in the low 4 bits
 192 – 207   PushGlobal     index in the low 4 bits
 208 – 223   PopGlobal      index in the low 4 bits
 224 – 255   PushLiteral    index in the low 4 bits
 ```

 Two bytes can select the same case. `PushLiteral` (the index is in the
 byte) and `PushLiteralExtended` (the index is in a word after the
 byte) are both `pushLiteral`. The listing keeps the two names: see
 `names`.

 The meaning of an operand is in its label:

 - `literal`: an index in the literals of the function;
 - `variable`, `index`: an index in the variables of a function;
 - `end`, `else`, `handler`, `target`: an offset in the code, where a
   branch leads.
 */
package enum Opcode: Equatable, Sendable {
    // MARK: Operators

    case binary(Operator)
    /** `and` and `or` skip their right side, which ends at `end`. */
    case and(end: Int)
    case or(end: Int)
    case not
    case negate
    case coerce

    // MARK: Values

    case pushLiteral(Int)
    /** A small number: -1, 0, 1, 2 or 3. */
    case pushInteger(Int)
    case pushTrue, pushFalse, pushEmpty, pushUndefined
    case pushMe, pushIt, pushNext
    case pushVariable(Int), popVariable(Int)
    /** A global is found by its name, which is a literal. */
    case pushGlobal(literal: Int), popGlobal(literal: Int)
    /** A variable of a script around this one: `depth` 1 is the nearest. */
    case pushParentVariable(depth: Int, index: Int), popParentVariable(depth: Int, index: Int)
    case pop, dup, gcSwap
    case getData, setData, copyData
    case storeResult, getResult
    case clone, objectAliasQuote
    case makeList, makeVector, makeRecord
    /** Builds an object specifier: see `SpecifierForm`. */
    case makeObjectAlias(form: SpecifierForm)
    /** A comparison inside `whose`. `index` is numbered like the bytes 0 to 12. */
    case makeComp(index: UInt8)
    case matchLiteral(literal: Int)

    // MARK: Calls

    /** A command, or a user handler with labeled parameters. The literal is the name. */
    case messageSend(literal: Int)
    case positionalMessageSend(literal: Int)
    case `continue`(literal: Int)
    case positionalContinue(literal: Int)
    case `return`
    case error

    // MARK: Blocks

    /**
     The meaning of the word is not known. The interpreter of the
     framework does not read it: it steps over it. It steps over the
     words of `consider`, `of`, `beginTransaction` and `matchLiteral`
     in the same way, so those are there for a reader of the code, like
     this tool, and not for the run.
     */
    case tell(word: Int)
    case endTell
    case consider(end: Int)
    case endConsider
    case errorHandler(handler: Int)
    case endErrorHandler(end: Int)
    /** The names of the variables of `on error`: two literals. */
    case handleError(message: Int, number: Int)
    case testIf(else: Int)
    case jump(target: Int)
    case linkRepeat(end: Int)
    case repeatNTimes, repeatWhile, repeatUntil
    case repeatInCollection(variable: Int), repeatInRange(variable: Int)
    case exit
    case of(end: Int)
    case endOf
    case beginTimeout, endTimeout
    case beginTransaction(end: Int)
    case endTransaction

    // MARK: Definitions

    case defineActor(literal: Int)
    case endDefineActor
    case defineProcedure(literal: Int), defineClosure(literal: Int), defineProperty(literal: Int)

    /** A byte without an operation. The listing names it `Undefined` or `None`. */
    case invalid

    /**
     Creates the operation of an opcode byte.

     `source` gives the operands that are stored after the byte. It is
     asked once for each operand, in order. An opcode from 160 to 255
     has no operand after it: its index is the low 4 bits of the byte.
     */
    package init(byte: UInt8, operands source: inout some OperandSource) {
        let compact = Int(byte & 0x0f)
        if let op = Operator(byte: byte) {
            self = .binary(op)
            return
        }
        self = switch byte {
        case 9: .and(end: source.target())
        case 10: .or(end: source.target())
        case 11: .not
        case 12: .messageSend(literal: source.word())
        case 13: .makeList
        case 14: .makeRecord
        case 15: .return
        case 16: .continue(literal: source.word())
        case 17: .objectAliasQuote
        case 18: .tell(word: source.word())
        case 19: .consider(end: source.target())
        case 20: .errorHandler(handler: source.target())
        case 21: .error
        case 22: .exit
        case 23: .linkRepeat(end: source.target())
        case 24: .repeatNTimes
        case 25: .repeatWhile
        case 26: .repeatUntil
        case 27: .repeatInCollection(variable: source.word())
        case 28: .repeatInRange(variable: source.word())
        case 29: .testIf(else: source.target())
        case 38: .coerce
        case 39: .negate
        case 40, 69: .getData
        case 41: .pushMe
        case 42: .pushIt
        case 43: .positionalMessageSend(literal: source.word())
        case 44 ... 55: SpecifierForm(rawValue: byte).map { .makeObjectAlias(form: $0) } ?? .invalid
        case 56 ... 68: .makeComp(index: byte - 56)
        case 70: .setData
        case 71: .copyData
        case 74: .positionalContinue(literal: source.word())
        case 75: .defineActor(literal: source.word())
        case 76: .defineProcedure(literal: source.word())
        case 77: .defineClosure(literal: source.word())
        case 78: .defineProperty(literal: source.word())
        case 79: .storeResult
        case 80: .getResult
        case 81: .clone
        case 82: .of(end: source.target())
        case 83: .endDefineActor
        case 84: .endOf
        case 85: .endTell
        case 86: .endConsider
        case 87: .endErrorHandler(end: source.target())
        case 88: .handleError(message: source.word(), number: source.word())
        case 89: .jump(target: source.target())
        case 90: .pop
        case 91: .dup
        case 92: .gcSwap
        case 93: .pushVariable(source.word())
        case 94: .popVariable(source.word())
        case 95: .pushGlobal(literal: source.word())
        case 96: .popGlobal(literal: source.word())
        case 97: .pushLiteral(source.word())
        case 98: .pushParentVariable(depth: source.word(), index: source.word())
        case 99: .popParentVariable(depth: source.word(), index: source.word())
        case 100: .pushNext
        case 101: .pushTrue
        case 102: .pushFalse
        case 103: .pushEmpty
        case 104: .pushUndefined
        case 105: .pushInteger(-1)
        case 106 ... 109: .pushInteger(Int(byte) - 106)
        case 110: .beginTimeout
        case 111: .endTimeout
        case 112: .beginTransaction(end: source.target())
        case 113: .endTransaction
        case 117: .matchLiteral(literal: source.word())
        case 118: .makeVector
        case 160 ... 175: .pushVariable(compact)
        case 176 ... 191: .popVariable(compact)
        case 192 ... 207: .pushGlobal(literal: compact)
        case 208 ... 223: .popGlobal(literal: compact)
        case 224 ... 255: .pushLiteral(compact)
        default: .invalid
        }
    }

    /** The operands, as the listing shows them: each one with its kind. */
    package var operands: [Operand] {
        switch self {
        case let .pushLiteral(index), let .pushGlobal(index), let .popGlobal(index), let .matchLiteral(index),
             let .messageSend(index), let .positionalMessageSend(index), let .continue(index), let .positionalContinue(index),
             let .defineActor(index), let .defineProcedure(index), let .defineClosure(index), let .defineProperty(index):
            [Operand(kind: .literalIndex, value: index)]
        case let .pushVariable(index), let .popVariable(index), let .repeatInCollection(index), let .repeatInRange(index):
            [Operand(kind: .variableIndex, value: index)]
        case let .pushParentVariable(depth, index), let .popParentVariable(depth, index):
            [Operand(kind: .parentDepth, value: depth), Operand(kind: .variableIndex, value: index)]
        case let .handleError(message, number):
            [Operand(kind: .literalIndex, value: message), Operand(kind: .literalIndex, value: number)]
        case let .and(target), let .or(target), let .consider(target), let .errorHandler(target), let .endErrorHandler(target),
             let .testIf(target), let .jump(target), let .linkRepeat(target), let .of(target), let .beginTransaction(target):
            [Operand(kind: .branchTarget, value: target)]
        case let .tell(word):
            [Operand(kind: .signedWord, value: word)]
        default:
            []
        }
    }

    /** The mnemonic of every opcode byte, indexed by the byte. The listing prints it. */
    package static let names: [String] = {
        var table = [String](repeating: "", count: 256)
        let first = [
            "Equal", "NotEqual", "GreaterThan", "GreaterThanOrEqual", "LessThan", "LessThanOrEqual",
            "StartsWith", "EndsWith", "Contains", "And", "Or", "Not", "MessageSend", "MakeList",
            "MakeRecord", "Return", "Continue", "ObjectAliasQuote", "Tell", "Consider", "ErrorHandler",
            "Error", "Exit", "LinkRepeat", "RepeatNTimes", "RepeatWhile", "RepeatUntil",
            "RepeatInCollection", "RepeatInRange", "TestIf", "Add", "Subtract", "Multiply", "Divide",
            "Quotient", "Remainder", "Power", "Concatenate", "Coerce", "Negate", "GetData", "PushMe",
            "PushIt", "PositionalMessageSend",
        ]
        for (index, name) in first.enumerated() {
            table[index] = name
        }
        for index in 44 ... 55 {
            table[index] = "MakeObjectAlias"
        }
        for index in 56 ... 68 {
            table[index] = "MakeComp"
        }
        let more: [Int: String] = [
            69: "GetData", 70: "SetData", 71: "CopyData", 72: "Undefined", 73: "Undefined",
            74: "PositionalContinue", 75: "DefineActor", 76: "DefineProcedure", 77: "DefineClosure",
            78: "DefineProperty", 79: "StoreResult", 80: "GetResult", 81: "Clone", 82: "Of",
            83: "EndDefineActor", 84: "EndOf", 85: "EndTell", 86: "EndConsider",
            87: "EndErrorHandler", 88: "HandleError", 89: "Jump", 90: "Pop", 91: "Dup",
            92: "GCSwap", 93: "PushVariableExtended", 94: "PopVariableExtended",
            95: "PushGlobalExtended", 96: "PopGlobalExtended", 97: "PushLiteralExtended",
            98: "PushParentVariable", 99: "PopParentVariable", 100: "PushNext", 101: "PushTrue",
            102: "PushFalse", 103: "PushEmpty", 104: "PushUndefined", 105: "PushMinus1",
            106: "Push0", 107: "Push1", 108: "Push2", 109: "Push3", 110: "BeginTimeout",
            111: "EndTimeout", 112: "BeginTransaction", 113: "EndTransaction", 114: "Undefined",
            115: "Undefined", 116: "Undefined", 117: "MatchLiteral", 118: "MakeVector",
        ]
        for (index, name) in more {
            table[index] = name
        }
        for index in 119 ... 127 {
            table[index] = "None"
        }
        for index in 128 ... 159 {
            table[index] = "Undefined"
        }
        for index in 160 ... 175 {
            table[index] = "PushVariable"
        }
        for index in 176 ... 191 {
            table[index] = "PopVariable"
        }
        for index in 192 ... 207 {
            table[index] = "PushGlobal"
        }
        for index in 208 ... 223 {
            table[index] = "PopGlobal"
        }
        for index in 224 ... 255 {
            table[index] = "PushLiteral"
        }
        return table
    }()
}

/** The meaning of an operand value. The raw text is used in the listing. */
package enum OperandKind: String, Sendable {
    case signedWord = "signed-word"
    case literalIndex = "literal-index"
    case variableIndex = "variable-index"
    case parentDepth = "parent-depth"
    case branchTarget = "branch-target"
}

/** One operand as the listing shows it: a value and what it means. */
package struct Operand: Equatable, Sendable {
    package var kind: OperandKind
    package var value: Int

    package init(kind: OperandKind, value: Int) {
        self.kind = kind
        self.value = value
    }
}

/**
 One decoded instruction.

 ```
 offset   raw
 0x0006   0c 00 03      byte 0x0c, MessageSend, opcode .messageSend(literal: 3)
 ```
 */
package struct Instruction: Sendable {
    /** Position of the opcode byte inside the function's code. */
    package var offset: Int
    /** The opcode byte. */
    package var byte: UInt8
    /** What the instruction does, with its operands. */
    package var opcode: Opcode
    /**
     The bytes of the instruction in one word: the first byte is the
     lowest one, and the highest byte is their number.

     ```
     0c 00 03        →   0x03_00_00_00_00_03_00_0c
     ```

     An instruction has five bytes at most: an opcode and two operand
     words. An array for each instruction is a block of memory for each
     one, and a megabyte of code has up to a million instructions.
     */
    private var packed: UInt64 = 0
    /** The opcode byte followed by its operand bytes. At most seven bytes are kept. */
    package var raw: [UInt8] {
        get {
            (0 ..< self.length).map { UInt8(truncatingIfNeeded: self.packed >> (8 * UInt64($0))) }
        }
        set {
            self.takeBytes(newValue, 0 ..< newValue.count)
        }
    }

    /** Takes the bytes of the instruction from the code: the bytes at `range`, the first seven at most. */
    package mutating func takeBytes(_ code: [UInt8], _ range: Range<Int>) {
        let count = min(range.count, 7)
        var packed = UInt64(count) << 56
        var shift: UInt64 = 0
        for index in range.lowerBound ..< range.lowerBound + count {
            packed |= UInt64(code[index]) << shift
            shift += 8
        }
        self.packed = packed
    }

    /** The number of bytes of the instruction: its opcode byte and its operand bytes. */
    package var length: Int {
        Int(self.packed >> 56)
    }

    /**
     The number of operands that are not in the code, because the code
     is cut off. They are the last ones, and their value in `opcode` is
     0. Only the last instruction of damaged code has some.
     */
    package var missingOperands: Int

    package init(offset: Int, byte: UInt8, opcode: Opcode, raw: [UInt8] = [], missingOperands: Int = 0) {
        self.offset = offset
        self.byte = byte
        self.opcode = opcode
        self.missingOperands = missingOperands
        self.raw = raw
    }

    /** The name of the opcode byte in the listing, for example `PushLiteralExtended`. */
    package var mnemonic: String {
        Opcode.names[Int(self.byte)]
    }

    /** The operands that are in the code, as the listing shows them. */
    package var operands: [Operand] {
        self.opcode.operands.dropLast(self.missingOperands)
    }
}
