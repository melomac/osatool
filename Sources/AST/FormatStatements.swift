extension SourceFormatter {
    /** Prints statements, one after the other, each ended by a line feed. */
    func statements(_ statements: [any Stmt], _ indent: Int) -> String {
        var out = ""
        for statement in statements {
            out += self.stmt(statement, indent)
            out += "\n"
        }
        return out
    }

    /**
     Prints one statement, with its margin. A statement is a block, with
     statements inside it, or one line (see `line`).
     */
    func stmt(_ statement: any Stmt, _ indent: Int) -> String {
        switch statement {
        case let node as If:
            self.ifBlock(node, indent)
        case let node as Repeat:
            self.inside(node).block(self.repeatHeader(node), node.body, end: "end repeat", indent)
        case let node as Try:
            self.tryBlock(node, indent)
        case let node as Tell:
            self.inside(node).block("tell " + self.expr(node.target, .or), node.body, end: "end tell", indent)
        case let node as Considering:
            self.consideringBlock(node, indent)
        case let node as Timeout:
            self.block("with timeout of " + self.expr(node.seconds) + " seconds", node.body, end: "end timeout", indent)
        case let node as Transaction:
            self.block("with transaction", node.body, end: "end transaction", indent)
        case let node as UsingTerms:
            self.inside(node).block(self.usingTermsHeader(node), node.body, end: "end using terms from", indent)
        case is Blank:
            ""
        default:
            if let object = (statement as? Expression)?.value as? ScriptObject {
                self.scriptObject(object, indent)
            } else {
                self.margin(indent) + self.line(statement)
            }
        }
    }

    /**
     The printer for the statements of a `tell` block. The compiler
     knows the words of an application only inside a `tell` block for
     it, and the printer follows it:

     ```
     tell application "Finder"                 the words of Finder
         tell application "System Events"      those of System Events, not of Finder
             tell me                           no change
             tell process 1                    no change
             tell current application          no application
     ```

     The application can be given by its name, its path or its
     identifier (see `applicationName`), not by a variable.
     */
    func inside(_ node: Tell) -> SourceFormatter {
        var inner = self
        let all = self.allTerms ?? self.terms
        inner.allTerms = all
        if let application = node.target?.applicationName {
            inner.terms = all?.scoped(to: application)
        } else if node.target is CurrentApplication {
            inner.terms = all
        } else {
            return self
        }
        return inner
    }

    /** The printer for the statements of a `using terms from` block: the words of its application are known there. */
    func inside(_ node: UsingTerms) -> SourceFormatter {
        guard let application = node.application?.applicationName else {
            return self
        }
        var inner = self
        let all = self.allTerms ?? self.terms
        inner.allTerms = all
        inner.terms = all?.scoped(to: application)
        inner.usingTerms = true
        return inner
    }

    /** The first line of a `using terms from` block. */
    func usingTermsHeader(_ node: UsingTerms) -> String {
        "using terms from " + (node.application.map { self.expr($0, .or) } ?? "scripting additions")
    }

    /** The printer for the statements of a loop: see `insideRepeatWith`. */
    func inside(_ node: Repeat) -> SourceFormatter {
        guard node.kind == .in || node.kind == .range else {
            return self
        }
        var inner = self
        inner.insideRepeatWith = true
        return inner
    }

    /**
     Prints a block: its first line, its statements one level deeper,
     and its last line.
     */
    func block(_ header: String, _ body: [any Stmt], end: String, _ indent: Int) -> String {
        let prefix = self.margin(indent)
        return prefix + header + "\n" + self.statements(body, indent + 1) + prefix + end
    }

    /** Prints a statement that is one line, without its margin. */
    func line(_ statement: any Stmt) -> String {
        switch statement {
        case let node as SetStmt:
            "set " + self.expr(node.target) + " to " + self.expr(node.value, .statement)
        case let node as Copy:
            "copy " + self.expr(node.source, .or) + " to " + self.expr(node.target)
        case let node as Expression:
            self.expr(node.value, .statement)
        case let node as ErrorStmt:
            self.parts(
                ["error"] + self.commandArguments(node.arguments, rawOnly: false, words: errorLabels),
                barred: ["error"] + self.barring.commandArguments(node.arguments, rawOnly: false, words: errorLabels),
            )
        case let node as Declaration:
            (node.global ? "global " : "local ") + node.names.map { self.name($0) }.joined(separator: ", ")
        case let node as Continue:
            node.call == nil ? "continue «unresolved»" : "continue " + self.expr(node.call, .statement)
        case let node as Return:
            node.value == nil ? "return" : "return " + self.expr(node.value, .statement)
        case is ExitRepeat:
            "exit repeat"
        case let node as Comment:
            "-- " + node.text
        default:
            "-- unsupported statement " + statement.nodeName
        }
    }

    /**
     Prints a `considering` or `ignoring` block:

     ```
     considering case, diacriticals and punctuation
     ignoring white space
     considering case but ignoring white space
     ```
     */
    func consideringBlock(_ node: Considering, _ indent: Int) -> String {
        if node.options.isEmpty, !node.ignored.isEmpty {
            return self.block("ignoring " + node.ignored.wordList, node.body, end: "end ignoring", indent)
        }
        var header = "considering " + node.options.wordList
        if !node.ignored.isEmpty {
            header += " but ignoring " + node.ignored.wordList
        }
        return self.block(header, node.body, end: "end considering", indent)
    }

    /**
     Prints an `if` block. An `else` part that is one `if` and nothing
     more is printed as `else if`:

     ```
     if a then
         …
     else if b then
         …
     else
         …
     end if
     ```
     */
    func ifBlock(_ node: If, _ indent: Int) -> String {
        let prefix = self.margin(indent)
        var out = ""
        var branch = node
        out += "\(prefix)if \(self.expr(branch.condition)) then\n"
        out += self.statements(branch.then, indent + 1)
        while branch.else.count == 1, let next = branch.else[0] as? If {
            out += "\(prefix)else if \(self.expr(next.condition)) then\n"
            out += self.statements(next.then, indent + 1)
            branch = next
        }
        if !branch.else.isEmpty {
            out += "\(prefix)else\n"
            out += self.statements(branch.else, indent + 1)
        }
        out += "\(prefix)end if"
        return out
    }

    /**
     Prints the first line of a `repeat` block:

     ```
     repeat                          repeat with x in list
     repeat 3 times                  repeat with i from 1 to 9
     repeat while a                  repeat with i from 1 to 9 by 2
     repeat until a
     ```
     */
    func repeatHeader(_ node: Repeat) -> String {
        switch node.kind {
        case .times:
            "repeat " + self.expr(node.times) + " times"
        case .while:
            "repeat while " + self.expr(node.condition)
        case .until:
            "repeat until " + self.expr(node.condition)
        case .in:
            "repeat with " + self.name(node.variable) + " in " + self.expr(node.collection, .or)
        case .range:
            self.parts(self.repeatRangeParts(node), barred: self.barring.repeatRangeParts(node))
        case .forever:
            "repeat"
        }
    }

    /** The parts of the first line of `repeat with i from 1 to 9 by 2`, each one with its word. */
    func repeatRangeParts(_ node: Repeat) -> [String] {
        var header = ["repeat with " + self.name(node.variable), "from " + self.expr(node.from), "to " + self.expr(node.to)]
        // The compiler always stores a step: 1 when the source has none.
        if let step = node.by, (step as? NumberLiteral).map({ $0.isReal || $0.integer != 1 }) ?? true {
            header.append("by " + self.expr(step))
        }
        return header
    }

    /** The parts of the line `on error message number n from f`, each one with its word. */
    func errorHeaderParts(_ node: Try) -> [String] {
        var header = ["on error"]
        if !node.errorName.isEmpty {
            header.append(self.name(node.errorName))
        }
        for parameter in node.parameters {
            header.append(parameter.label.rawValue + " " + self.expr(parameter.value, .term))
        }
        return header
    }

    /**
     Prints a `try` block. The `on error` line is printed when the block
     has statements for an error, or a variable that receives one:

     ```
     try
         …
     on error message number n partial result p from f to t
         …
     end try
     ```
     */
    func tryBlock(_ node: Try, _ indent: Int) -> String {
        let prefix = self.margin(indent)
        var out = prefix + "try\n" + self.statements(node.body, indent + 1)
        if !node.errorBody.isEmpty || !node.errorName.isEmpty || !node.parameters.isEmpty {
            out += prefix + self.parts(self.errorHeaderParts(node), barred: self.barring.errorHeaderParts(node)) + "\n"
            out += self.statements(node.errorBody, indent + 1)
        }
        out += prefix + "end try"
        return out
    }
}
