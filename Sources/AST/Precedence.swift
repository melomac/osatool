/**
 How tightly a piece of source holds together, from loose to tight.

 Each place where an expression is written asks for a level, and each
 expression has a level of its own. An expression whose level is lower
 than the one its place asks for is put in parentheses.

 ```
 statement        a whole statement, or the value of `set` and `return`
 value            an item of a list, an argument, a condition
 or
 and
 not
 comparison       =  ≠  <  >  ≤  ≥  starts with  ends with  contains
 coercion         as
 concatenation    &
 addition         +  -
 multiplication   *  /  div  mod
 power            ^
 negation         the minus sign of `-x`
 reference        a part of `x of y`
 term             one word, or anything in parentheses
 ```

 A call to a command has the level `statement`: it stands bare as a
 statement, and has parentheses everywhere else.

 The order of the operators is the one of the compiler, and it was read
 from the compiler: for each pair of operators, `a OP1 b OP2 c` was
 compiled bare and with parentheses on each side, and the code of the
 three was compared.

 The compiler has three levels of comparison: `=` is the loosest and
 `contains` the tightest, so `a = b < c` is `a = (b < c)`. That is hard
 to read, and two comparisons of the same level do not compile in a row.
 So the printer has one level, and a comparison inside another one
 always has parentheses.

 The printer of Apple's tools has its own table of levels, read in the
 framework: `=` 90, `<` 100, `as` 110, `contains` 120, `&` 130. It is
 not the order of the compiler for `as`: the compiler reads
 `a contains b as text` as `a contains (b as text)`, and their printer
 then writes these parentheses, because its `as` is below `contains`.
 This printer writes them too (see `operand`).
 */
enum Precedence: Int, Comparable {
    case statement
    case value
    case or
    case and
    case not
    case comparison
    case coercion
    case concatenation
    case addition
    case multiplication
    case power
    case negation
    case reference
    case term

    static func < (left: Precedence, right: Precedence) -> Bool {
        left.rawValue < right.rawValue
    }

    /** The level after this one: a little tighter. `term` is the last. */
    var next: Precedence {
        Precedence(rawValue: self.rawValue + 1) ?? .term
    }
}

extension BinaryKind {
    /** The level of the operator. */
    var precedence: Precedence {
        switch self {
        case .or: .or
        case .and: .and
        case .equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual, .startsWith, .endsWith, .contains: .comparison
        case .concatenate: .concatenation
        case .add, .subtract: .addition
        case .multiply, .divide, .quotient, .remainder: .multiplication
        case .power: .power
        case .of: .reference
        }
    }

    /** True for `+ - * / div mod ^`. */
    var isArithmetic: Bool {
        switch self.precedence {
        case .addition, .multiplication, .power: true
        default: false
        }
    }

    /**
     True when a row of operators of this level needs no parentheses,
     and is read from the left: `a - b - c` is `(a - b) - c`.

     False for the comparisons: `a = b = c` does not compile. False for
     `^` too: the compiler reads `a ^ b ^ c` from the right, as
     `a ^ (b ^ c)`, and Apple's tools always write these parentheses.
     */
    var groupsFromLeft: Bool {
        switch self.precedence {
        case .comparison, .power: false
        default: true
        }
    }
}
