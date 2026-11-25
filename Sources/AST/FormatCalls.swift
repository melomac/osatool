import Extensions
import Terminology

extension SourceFormatter {
    /**
     Prints a command call, without parentheses around it:

     ```
     display dialog "x" buttons {"OK"} with hidden answer
     └ name ──────┘ └ direct, then each labeled argument ┘
     target's «event abcdefgh» 2 given «class kfil»:3
     ```
     */
    func commandCall(_ node: CommandCall) -> String {
        // `get` and `set` are statements of the language, with their own
        // instructions. An event with their code can only be written raw.
        let isRawOnly = node.code == "coregetd" || node.code == "coresetd"
        var name = isRawOnly ? "" : node.name
        if name.isEmpty, !isRawOnly, let command = terms?.command(node.code) {
            name = command.name
        }
        if name.isEmpty {
            name = node.code.rawEvent
        }
        var call = name
        let arguments = self.commandArguments(node.arguments, rawOnly: isRawOnly)
        if !arguments.isEmpty {
            call += " " + self.parts(arguments, barred: self.barring.commandArguments(node.arguments, rawOnly: isRawOnly))
        }
        if node.target != nil {
            call = self.expr(node.target, .term) + "'s " + call
        }
        return call
    }

    /**
     Prints the arguments of a command call, in order.

     A label is written like a preposition, `to x`, only when the
     command gives it that word: the decompiler puts the word in the
     argument. Any other label can only be written after `given`, so
     these arguments come last. The word that another command has for
     the same code is not used: `as text` or `name v` after an unknown
     command would be read as something else. After `given`, and after
     `with`, a label is the word of its code, like any property:

     ```
     «event abcdefgh» 2 given «class kfil»:3, name:v
     «event abcdefgh» with «class flag» without name
     ```

     - `rawOnly`: no label is printed as a word.
     - `words`: the words of the labels of a statement of the language,
       which no dictionary gives: see `errorLabels`.
     */
    func commandArguments(_ arguments: [any Argument], rawOnly: Bool, words: [Code4: String] = [:]) -> [String] {
        var args: [String] = []
        var given: [String] = []
        // `with a and b`: flags that follow each other with the same value.
        var flags: (enabled: Bool, labels: [String])?
        func endFlags() {
            if let done = flags {
                args.append((done.enabled ? "with " : "without ") + done.labels.wordList)
                flags = nil
            }
        }
        func addFlag(_ label: String, _ enabled: Bool) {
            if let open = flags, open.enabled != enabled {
                endFlags()
            }
            flags = (enabled, (flags?.labels ?? []) + [label])
        }
        for argument in arguments {
            switch argument {
            case let value as DirectArgument:
                endFlags()
                // `x whose test` takes all that follows, so it has
                // parentheses: `count (every file whose size > 9)`.
                args.append(self.argumentValue(value.value, .or))
            case let value as NamedArgument:
                let name = value.name.isEmpty ? words[value.code] ?? "" : value.name
                if !rawOnly, !name.isEmpty {
                    endFlags()
                    args.append(name + " " + self.argumentValue(value.value, .value))
                } else if let boolean = value.value as? BooleanLiteral {
                    // `given «class flag»:true` is `with «class flag»`.
                    addFlag(self.labelWord(value.code, rawOnly: rawOnly), boolean.value)
                } else {
                    given.append(self.labelWord(value.code, rawOnly: rawOnly) + ":" + self.expr(value.value, .term))
                }
            case let value as FlagArgument:
                addFlag(rawOnly || value.name.isEmpty ? self.labelWord(value.code, rawOnly: rawOnly) : value.name, value.enabled)
            default:
                endFlags()
            }
        }
        endFlags()
        if !given.isEmpty {
            args.append("given " + given.joined(separator: ", "))
        }
        return args
    }

    /**
     Returns a label as it is written after `given` or `with`: the word
     of its code where the script is, or its raw form.
     */
    func labelWord(_ code: Code4, rawOnly: Bool) -> String {
        rawOnly ? code.rawClass : self.terms?.term(code) ?? code.rawClass
    }

    /**
     The labels of the `error` statement. They are words of the
     language itself:

     ```
     error "text" number 42 partial result {1} from x to integer
     ```
     */
    var errorLabels: [Code4: String] {
        ["errn": "number", "ptlr": "partial result", "erob": "from", "errt": "to"]
    }

    /**
     Prints the value of an argument of a command. A coercion has
     parentheses. Without them the compiler reads `as` as a parameter
     of the command, or as a coercion of what the command gives back:

     ```
     do shell script (x as text)     not `do shell script x as text`
     write x to (f as alias)         not `write x to f as alias`
     ```
     */
    func argumentValue(_ value: any Expr?, _ place: Precedence) -> String {
        let text = self.expr(value, place)
        return value is Coerce ? "(" + text + ")" : text
    }

    /**
     True for a call that is printed with a colon after each part of the
     name: `text's stringByAppendingString:other`. A method of an
     Objective-C object has one `_` in its name for each argument.
     */
    func isInterleaved(_ node: HandlerCall) -> Bool {
        guard
            node.target != nil,
            !node.arguments.isEmpty,
            node.name.hasSuffix("_")
        else {
            return false
        }
        let parts = node.name.split(separator: "_", omittingEmptySubsequences: false).dropLast()
        return parts.count == node.arguments.count && parts.allSatisfy { !$0.isEmpty }
    }

    /**
     Prints a call to a user handler, without parentheses around it:

     ```
     name(a, b)                        no target
     my name(a, b)                     the target is `me`
     target's name(a, b)
     target's first:a second:b         see `isInterleaved`
     ```
     */
    func handlerCall(_ node: HandlerCall) -> String {
        let call: String
        if self.isInterleaved(node) {
            let parts = node.name.split(separator: "_", omittingEmptySubsequences: false).dropLast()
            // Before a colon too, a word of the language needs bars: `|error|:`, `|count|:`.
            call = zip(parts, node.arguments).map { self.name(String($0)) + ":" + self.term($1) }.joined(separator: " ")
        } else {
            call = self.name(node.name) + "(" + node.arguments.map { self.expr($0) }.joined(separator: ", ") + ")"
        }
        guard let target = node.target else {
            return call
        }
        if target is Me {
            return "my " + call
        }
        return self.owner(target) + "'s " + call
    }

    /**
     Prints the owner in `owner's name`. A property of something is
     written the same way, so that no parentheses are needed:
     `current application's NSString's …`.
     */
    func owner(_ expression: any Expr) -> String {
        if let node = expression as? Specifier, node.kind == .property, let container = node.container, !(container is It) {
            return self.owner(container) + "'s " + self.expr(node.object, .reference)
        }
        let text = self.expr(expression, .term)
        return expression is Specifier ? "(" + text + ")" : text
    }

    /**
     Prints a call to a user handler with labeled parameters, without
     parentheses around it.

     The parts come in the order the language asks for:

     ```
     name of direct  above 1 under 2  with a and b  without c  given d:1, e:2
          └ direct ┘ └ prepositions ┘ └ true ─────┘ └ false ─┘ └ other values ┘
     ```

     A value that is an operation is put in parentheses, so that it
     cannot be read as part of the next label.
     */
    func labeledCall(_ node: LabeledCall) -> String {
        self.parts(self.labeledCallParts(node), barred: self.barring.labeledCallParts(node))
    }

    /** The parts of a labeled call, in order: the name, then each group of parameters with its word. */
    func labeledCallParts(_ node: LabeledCall) -> [String] {
        var call = [self.name(node.name)]
        if node.direct != nil {
            call.append("of " + self.expr(node.direct, .term))
        }
        var enabled: [String] = []
        var disabled: [String] = []
        var given: [String] = []
        for argument in node.arguments {
            if case let .code(code) = argument.label, let word = handlerPrepositions[code] {
                call.append(word + " " + self.expr(argument.value, .term))
                continue
            }
            let label = self.givenLabel(argument.label)
            if let boolean = argument.value as? BooleanLiteral {
                if boolean.value {
                    enabled.append(label)
                } else {
                    disabled.append(label)
                }
            } else {
                given.append(label + ":" + self.expr(argument.value, .term))
            }
        }
        if !enabled.isEmpty {
            call.append("with " + enabled.wordList)
        }
        if !disabled.isEmpty {
            call.append("without " + disabled.wordList)
        }
        if !given.isEmpty {
            call.append("given " + given.joined(separator: ", "))
        }
        return call
    }
}
