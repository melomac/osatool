/**
 The children of each node.

 A node knows the expressions it holds directly. Code that goes through
 the tree (a pass, a search, a count) uses these methods, and does not
 have to list the fields of every kind of node again:

 ```
 Binary ──┬── left
          └── right          rewriteChildren visits left, then right
 If ──┬── condition          rewriteExpressions visits the condition
      ├── then  [statements]
      └── else  [statements] bodies gives the two lists
 ```
 */

// MARK: Expressions

package extension Expr {
    /** The expressions directly inside this one, in order. */
    var children: [any Expr] {
        var found: [any Expr] = []
        self.rewriteChildren { child in
            if let child {
                found.append(child)
            }
            return child
        }
        return found
    }
}

package extension List {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        for index in self.elements.indices {
            self.elements[index] = rewrite(self.elements[index])
        }
    }
}

package extension Record {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        for index in self.fields.indices {
            self.fields[index].label = rewrite(self.fields[index].label)
            self.fields[index].value = rewrite(self.fields[index].value)
        }
    }
}

package extension Unary {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.value = rewrite(self.value)
    }
}

package extension Binary {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.left = rewrite(self.left)
        self.right = rewrite(self.right)
    }
}

package extension Coerce {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.value = rewrite(self.value)
        self.type = rewrite(self.type)
    }
}

package extension GetExpr {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.value = rewrite(self.value)
    }
}

package extension Reference {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.value = rewrite(self.value)
    }
}

package extension CopyExpr {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.value = rewrite(self.value)
    }
}

package extension CommandCall {
    /** The target, then the value of each direct or named argument. */
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.target = rewrite(self.target)
        self.arguments.rewriteValues(rewrite)
    }
}

package extension [any Argument] {
    /** Replaces the value of each direct or named argument with `rewrite(value)`. */
    mutating func rewriteValues(_ rewrite: (any Expr?) -> (any Expr)?) {
        for (index, argument) in self.enumerated() {
            switch argument {
            case var value as DirectArgument:
                value.value = rewrite(value.value)
                self[index] = value
            case var value as NamedArgument:
                value.value = rewrite(value.value)
                self[index] = value
            default:
                break
            }
        }
    }
}

package extension LabeledCall {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.direct = rewrite(self.direct)
        for index in self.arguments.indices {
            self.arguments[index].value = rewrite(self.arguments[index].value)
        }
    }
}

package extension HandlerCall {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.target = rewrite(self.target)
        for index in self.arguments.indices {
            self.arguments[index] = rewrite(self.arguments[index])
        }
    }
}

package extension Specifier {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.object = rewrite(self.object)
        self.container = rewrite(self.container)
        self.from = rewrite(self.from)
        self.to = rewrite(self.to)
    }
}

package extension Whose {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.object = rewrite(self.object)
        self.predicate = rewrite(self.predicate)
    }
}

package extension ContinueExpr {
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.call = rewrite(self.call)
    }
}

package extension ScriptObject {
    /**
     The values of the properties. The script objects and the handlers
     inside this one are not expressions: `rewriteExpression` enters them.
     */
    func rewriteChildren(_ rewrite: (any Expr?) -> (any Expr)?) {
        for index in self.properties.indices {
            self.properties[index].value = rewrite(self.properties[index].value)
        }
    }
}

// MARK: - Statements

package extension SetStmt {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.target = rewrite(self.target)
        self.value = rewrite(self.value)
    }
}

package extension Copy {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.source = rewrite(self.source)
        self.target = rewrite(self.target)
    }
}

package extension Expression {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.value = rewrite(self.value)
    }
}

package extension ErrorStmt {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.arguments.rewriteValues(rewrite)
    }
}

package extension If {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.condition = rewrite(self.condition)
    }

    var bodies: [[any Stmt]] {
        [self.then, self.else]
    }
}

package extension Repeat {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.times = rewrite(self.times)
        self.condition = rewrite(self.condition)
        self.collection = rewrite(self.collection)
        self.from = rewrite(self.from)
        self.to = rewrite(self.to)
        self.by = rewrite(self.by)
    }

    var bodies: [[any Stmt]] {
        [self.body]
    }
}

package extension Try {
    var bodies: [[any Stmt]] {
        [self.body, self.errorBody]
    }
}

package extension Tell {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.target = rewrite(self.target)
    }

    var bodies: [[any Stmt]] {
        [self.body]
    }
}

package extension Considering {
    var bodies: [[any Stmt]] {
        [self.body]
    }
}

package extension Timeout {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.seconds = rewrite(self.seconds)
    }

    var bodies: [[any Stmt]] {
        [self.body]
    }
}

package extension Transaction {
    var bodies: [[any Stmt]] {
        [self.body]
    }
}

package extension UsingTerms {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.application = rewrite(self.application)
    }

    var bodies: [[any Stmt]] {
        [self.body]
    }
}

package extension Continue {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.call = rewrite(self.call)
    }
}

package extension Return {
    func rewriteExpressions(_ rewrite: (any Expr?) -> (any Expr)?) {
        self.value = rewrite(self.value)
    }
}

// MARK: - Walking the tree

package extension [any Stmt] {
    /**
     Applies `rewrite` to every expression of the statements, at any depth.
     The children of an expression are rewritten before the expression.

     A missing expression (`nil`) stays `nil` and `rewrite` is not called.
     A script object inside an expression is entered: its properties, the
     script objects in it, and its handlers.
     */
    func rewriteEveryExpression(_ rewrite: (any Expr?) -> (any Expr)?) {
        for statement in self {
            statement.rewriteExpressions { $0?.rewriteWithChildren(rewrite) }
            for body in statement.bodies {
                body.rewriteEveryExpression(rewrite)
            }
        }
    }
}

package extension Expr {
    /**
     Rewrites the children of the expression, then the expression itself.

     - Returns: what `rewrite` gives for the expression.
     */
    func rewriteWithChildren(_ rewrite: (any Expr?) -> (any Expr)?) -> (any Expr)? {
        self.rewriteChildren { $0?.rewriteWithChildren(rewrite) }
        if let object = self as? ScriptObject {
            object.rewriteContents(rewrite)
        }
        return rewrite(self)
    }
}

private extension ScriptObject {
    /** Rewrites what a script object holds besides its own properties. */
    func rewriteContents(_ rewrite: (any Expr?) -> (any Expr)?) {
        for child in self.objects {
            child.rewriteChildren { $0?.rewriteWithChildren(rewrite) }
            child.rewriteContents(rewrite)
        }
        for handler in self.handlers {
            handler.body.rewriteEveryExpression(rewrite)
        }
    }
}
