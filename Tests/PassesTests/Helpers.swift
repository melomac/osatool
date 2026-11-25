import AST
import Extensions
@testable import Passes
import Terminology
import Testing

/** Builds `a & b & c …`, grouped from the left. No operand gives `""`. */
func concatenate(_ expressions: [any Expr]) -> any Expr {
    guard var result = expressions.first else {
        return StringLiteral()
    }
    for expression in expressions.dropFirst() {
        result = Binary(op: .concatenate, left: result, right: expression)
    }
    return result
}

func concatenate(_ expressions: any Expr...) -> any Expr {
    concatenate(expressions)
}
