import Extensions

/** `set target to value`. */
package final class SetStmt: Stmt {
    package var target: any Expr?
    package var value: any Expr?

    package init(target: any Expr? = nil, value: any Expr? = nil) {
        self.target = target
        self.value = value
    }
}

/** `copy source to target`. */
package final class Copy: Stmt {
    package var source: any Expr?
    package var target: any Expr?

    package init(source: any Expr? = nil, target: any Expr? = nil) {
        self.source = source
        self.target = target
    }
}

/** An expression used as a statement, for example a command call. */
package final class Expression: Stmt {
    package var value: any Expr?

    package init(value: any Expr? = nil) {
        self.value = value
    }
}

/**
 The `error` statement, which stops the handler with an error:

 ```
 error "message" number 42 from x to t partial result p
       └ direct ┘ └ each other part is a named argument ─┘
 ```

 It is a statement of the language with its own instruction, not a
 command: it has no event code, and it is never inside parentheses.
 */
package final class ErrorStmt: Stmt {
    package var arguments: [any Argument]

    package init(arguments: [any Argument] = []) {
        self.arguments = arguments
    }
}

/** `local a, b` or `global a, b`. */
package final class Declaration: Stmt {
    package var names: [String]
    package var global: Bool

    package init(names: [String] = [], global: Bool = false) {
        self.names = names
        self.global = global
    }
}

package final class If: Stmt {
    package var condition: any Expr?
    package var then: [any Stmt]
    package var `else`: [any Stmt]

    package init(condition: any Expr? = nil, then: [any Stmt] = [], else: [any Stmt] = []) {
        self.condition = condition
        self.then = then
        self.else = `else`
    }
}

package enum RepeatKind: String, Sendable {
    case forever
    case times
    case `while`
    case until
    case `in`
    case range
}

/**
 A `repeat` block. Which fields are used depends on `kind`:

 ```
 forever   repeat
 times     repeat <times> times
 while     repeat while <condition>
 until     repeat until <condition>
 in        repeat with <variable> in <collection>
 range     repeat with <variable> from <from> to <to> [by <by>]
 ```
 */
package final class Repeat: Stmt {
    package var kind: RepeatKind
    package var variable: String
    package var times: any Expr?
    package var condition: any Expr?
    package var collection: any Expr?
    package var from: any Expr?
    package var to: any Expr?
    package var by: any Expr?
    package var body: [any Stmt]

    package init(
        kind: RepeatKind = .forever, variable: String = "", times: any Expr? = nil,
        condition: any Expr? = nil, collection: any Expr? = nil, from: any Expr? = nil, to: any Expr? = nil,
        by: any Expr? = nil, body: [any Stmt] = [],
    ) {
        self.kind = kind
        self.variable = variable
        self.times = times
        self.condition = condition
        self.collection = collection
        self.from = from
        self.to = to
        self.by = by
        self.body = body
    }
}

/** What a part of an `on error` line receives, after the message. */
package enum ErrorLabel: String, Sendable {
    case number
    case from
    case to
    case partialResult = "partial result"

    /** The label stored with this code, or `nil` for another code. */
    package init?(code: Code4) {
        switch code {
        case "errn": self = .number
        case "erob": self = .from
        case "errt": self = .to
        case "ptlr": self = .partialResult
        default: return nil
        }
    }
}

/**
 One part of an `on error` line after the message: its label, and the
 variable that receives the value. A number can stand for the variable:
 `on error number -128` handles that error only.
 */
package struct ErrorParameter {
    package var label: ErrorLabel
    package var value: any Expr

    package init(_ label: ErrorLabel, _ value: any Expr) {
        self.label = label
        self.value = value
    }
}

/**
 A `try` block.

 ```
 try
     …                                              body
 on error message number n from f to t partial result p
          └ errorName ┘ └ parameters, in the order of the source ┘
     …                                              errorBody
 end try
 ```
 */
package final class Try: Stmt {
    package var body: [any Stmt]
    /** The variable that receives the message, or nothing. */
    package var errorName: String
    package var parameters: [ErrorParameter]
    package var errorBody: [any Stmt]

    package init(body: [any Stmt] = [], errorName: String = "", parameters: [ErrorParameter] = [], errorBody: [any Stmt] = []) {
        self.body = body
        self.errorName = errorName
        self.parameters = parameters
        self.errorBody = errorBody
    }

    /** The names of the variables that the `on error` line sets. */
    package var names: [String] {
        (self.errorName.isEmpty ? [] : [self.errorName]) + self.parameters.compactMap { ($0.value as? Variable)?.name }
    }
}

package final class Tell: Stmt {
    package var target: any Expr?
    package var body: [any Stmt]

    package init(target: any Expr? = nil, body: [any Stmt] = []) {
        self.target = target
        self.body = body
    }
}

/**
 A `considering` or `ignoring` block. It says how text is compared in
 its statements, and whether the answers of applications are waited for:

 ```
 considering case, diacriticals and punctuation … end considering
 ignoring white space and hyphens … end ignoring
 considering case but ignoring white space … end considering
 ignoring application responses … end ignoring
 ```

 The compiler keeps two lists, and not which one the source gave first.
 */
package final class Considering: Stmt {
    /** The attributes that are considered. */
    package var options: [String]
    /** The attributes that are ignored. */
    package var ignored: [String]
    package var body: [any Stmt]

    package init(options: [String] = [], ignored: [String] = [], body: [any Stmt] = []) {
        self.options = options
        self.ignored = ignored
        self.body = body
    }
}

/** `with timeout of seconds seconds`. */
package final class Timeout: Stmt {
    package var seconds: any Expr?
    package var body: [any Stmt]

    package init(seconds: any Expr? = nil, body: [any Stmt] = []) {
        self.seconds = seconds
        self.body = body
    }
}

package final class Transaction: Stmt {
    package var body: [any Stmt]

    package init(body: [any Stmt] = []) {
        self.body = body
    }
}

/** `continue call`: passes the message to the parent handler. */
package final class Continue: Stmt {
    package var call: any Expr?

    package init(call: any Expr? = nil) {
        self.call = call
    }
}

package final class Return: Stmt {
    package var value: any Expr?
    package var explicit: Bool

    package init(value: any Expr? = nil, explicit: Bool = false) {
        self.value = value
        self.explicit = explicit
    }
}

package final class ExitRepeat: Stmt {
    package init() {}
}

/**
 An empty line that ends a block. The compiler writes code for it:
 the block then gives back the result of the statement before.

 ```
 on f()
     log 1
                 StoreResult, GetResult
 end f
 ```
 */
package final class Blank: Stmt {
    package init() {}
}

/**
 `using terms from application "Finder"` … `end using terms from`.
 Without an application: `using terms from scripting additions`.
 */
package final class UsingTerms: Stmt {
    package var application: any Expr?
    package var body: [any Stmt]

    package init(application: any Expr? = nil, body: [any Stmt] = []) {
        self.application = application
        self.body = body
    }
}

package final class Comment: Stmt {
    package var text: String

    package init(text: String = "") {
        self.text = text
    }
}
