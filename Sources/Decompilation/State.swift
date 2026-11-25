import AST
import Bytecode
import Extensions
import FAS
import Model
import Terminology

/**
 How deep one expression can be. A long chain of `&`, as some scripts
 make to hide a text, is as deep as it is long, so the limit is far
 above what was seen; the printer is still fast at that depth.
 */
let maximumExpressionDepth = 50000

/** How many blocks can be open, one inside the other. */
let maximumBlockDepth = 1024

/**
 What an open block is, with the node that receives its statements.

 An `of` scope is not a block of statements: it builds the expression
 `value of container`. `stackBase` is the height of the stack when the
 scope was opened.
 */
enum Scope {
    case root
    case `if`(If)
    case `repeat`(Repeat)
    case `try`(Try)
    case tell(Tell)
    case consider(Considering)
    case timeout(Timeout)
    case transaction(Transaction)
    case of(container: any Expr, stackBase: Int)

    var ifNode: If? {
        if case let .if(node) = self {
            node
        } else {
            nil
        }
    }

    var repeatNode: Repeat? {
        if case let .repeat(node) = self {
            node
        } else {
            nil
        }
    }

    var tryNode: Try? {
        if case let .try(node) = self {
            node
        } else {
            nil
        }
    }

    var tellNode: Tell? {
        if case let .tell(node) = self {
            node
        } else {
            nil
        }
    }

    var considerNode: Considering? {
        if case let .consider(node) = self {
            node
        } else {
            nil
        }
    }

    var timeoutNode: Timeout? {
        if case let .timeout(node) = self {
            node
        } else {
            nil
        }
    }

    var transactionNode: Transaction? {
        if case let .transaction(node) = self {
            node
        } else {
            nil
        }
    }

    var ofScope: (container: any Expr, stackBase: Int)? {
        if case let .of(container, stackBase) = self {
            (container, stackBase)
        } else {
            nil
        }
    }

    /** The statement the block becomes when it is closed. */
    var statement: any Stmt? {
        switch self {
        case .root, .of: nil
        case let .if(node): node
        case let .repeat(node): node
        case let .try(node): node
        case let .tell(node): node
        case let .consider(node): node
        case let .timeout(node): node
        case let .transaction(node): node
        }
    }
}

/**
 A block that is still open while the bytecode is walked.

 - `elseAt`: the offset where the second part starts (`else`, `on error`).
 - `endAt`: the offset where the block ends, or 0 when not known yet.
 - `inElse`: true once statements go to the second part.
 - `stackBase`: see `State.open`.
 */
final class Block {
    let scope: Scope
    var elseAt: Int
    var endAt: Int
    var inElse = false
    /** The size of the stack when the block was opened: what is above belongs to its statements. */
    var stackBase = 0

    init(_ scope: Scope, elseAt: Int = 0, endAt: Int = 0) {
        self.scope = scope
        self.elseAt = elseAt
        self.endAt = endAt
    }
}

/** The left side of an `and` / `or` waiting for its right side. */
struct LogicState {
    var op: BinaryKind
    var left: any Expr?
    var end: Int
}

/**
 The state of one function while its bytecode is walked.

 ```
 stack     expressions built so far, like the runtime value stack
 blocks    open blocks, innermost last; blocks[0] is the handler body
 pending   the target of an assignment waiting for its value
 pattern   the parts of `set {a, b} to …` found so far
 logic     open `and` / `or` operations
 ```
 */
final class State {
    let decompiler: Decompiler
    let function: Function
    let handler: Handler
    var stack: [any Expr] = []
    var blocks: [Block] = [Block(.root)]
    /** The `using terms from` blocks met so far, each with the block it is in: see `terms`. */
    var usingTermsScopes: [(block: Block, application: ApplicationName)] = []
    var pending: any Expr?
    /** The parts of an assignment to a pattern, found so far: see `PatternPart`. */
    var patternParts: [PatternPart] = []
    /** The value the parts come from. */
    var patternBase: any Expr?
    /** The last container removed after its parts were made: see `sharedContainer`. */
    var sharedContainerSeen: any Expr?
    var previous: Opcode?
    var variables: [String]
    var parentScopes: [NameScope]
    var logic: [LogicState] = []
    var underflow = false
    /** How many tables up the farthest name read or set with `PushParentVariable` is. */
    var parentDepth = 0
    /** The names read or set as globals, in the order they are first used. */
    var globalNames: [String] = []
    /** The names of `globalNames` and of `localNames`, to find one without reading the whole list. */
    private var knownGlobals: Set<String> = []
    private var knownLocals: Set<String> = []
    /** The names of the variables read or set as locals, in the order they are first used. */
    var localNames: [String] = []
    /** The size, the depth and the bytes of text of each expression seen in this function: see `measure`. */
    var sizes: [ObjectIdentifier: (node: any Expr, size: Int, depth: Int, text: Int)] = [:]
    /** The bytes of text of all these expressions, each one counted once. */
    var distinctText = 0
    /** The expressions that a statement has printed: see `printedAgain`. */
    var printed: Set<ObjectIdentifier> = []
    /** True once a block that is nested too deep was refused: see `open`. */
    var reportedTooDeep = false
    /** The limits of `push` and of `open`. A test gives them small values. */
    var expressionDepthLimit = maximumExpressionDepth
    var blockDepthLimit = maximumBlockDepth
    /** The sum of the sizes of the expressions of the statements emitted so far. */
    var emittedSize = 0
    /** True once a diagnostic says that the function is too large. */
    var reportedTooLarge = false

    init(decompiler: Decompiler, function: Function, handler: Handler, variables: [String] = [], parentScopes: [NameScope] = []) {
        self.decompiler = decompiler
        self.function = function
        self.handler = handler
        self.variables = variables
        self.parentScopes = parentScopes
    }

    /**
     Adds a statement to the innermost open block.

     A `continue` whose result is not used arrives here as an expression
     statement. It is stored as the `Continue` statement.
     */
    func emit(_ statement: any Stmt) {
        // Parts of a pattern that never got their end come first.
        if !self.patternParts.isEmpty {
            self.flushPatternParts()
        }
        var statement = statement
        if let expression = statement as? Expression, let node = expression.value as? ContinueExpr {
            statement = Continue(call: node.call)
        }
        // The same expression can be used by many statements. The sum of
        // what they print is limited like one expression is in `push`.
        var repeats: [ObjectIdentifier: (size: Int, text: Int)] = [:]
        statement.rewriteExpressions { expression in
            if let expression {
                self.emittedSize = self.emittedSize.addingSaturating(self.size(of: expression))
                self.findRepeats(expression, &repeats)
            }
            return expression
        }
        let text = repeats.values.reduce(0) { $0.addingSaturating($1.text) }
        self.decompiler.repeatedText = self.decompiler.repeatedText.addingSaturating(text)
        // Past a limit, a large part that was printed before is replaced
        // by a mark. The rest of the statement is written: what is new
        // in it, and what is small. So nothing can be hidden behind the
        // statements that used up the limit, or next to a large part.
        let tooManyNodes = self.emittedSize > 8 * self.sizes.count + 65536
        let tooMuchText = self.decompiler.repeatedText > maximumRepeatedText
        let large = repeats.filter { part in
            (tooManyNodes && part.value.size > maximumRepeatedPart) || (tooMuchText && part.value.text > LiteralPath.smallBytes)
        }
        if !large.isEmpty {
            if tooManyNodes {
                self.reportTooLarge()
            } else if !self.decompiler.reportedRepeatedText {
                self.decompiler.reportedRepeatedText = true
                self.decompiler.report(self.function.offset, "the script prints the same long texts again and again: they are printed as \(printedAboveMark) after the first times")
            }
            let marked = Set(large.keys)
            statement.rewriteExpressions { $0.map { self.withoutRepeats($0, marked) } }
        }
        self.append(statement)
    }

    /**
     Notes that a statement prints an expression, and finds the parts
     of it that were printed before, by this statement or by another
     one. Each one goes to `repeats` with its number of nodes and its
     bytes of text.

     ```
     set a to big & 1        nothing was printed before
     set b to big & 2        `big` was: its size, and its text
     ```

     Only the parts that are new are read, so the cost is small even
     when one part is used a million times.
     */
    func findRepeats(_ node: any Expr, _ repeats: inout [ObjectIdentifier: (size: Int, text: Int)]) {
        let identity = ObjectIdentifier(node)
        if !self.printed.insert(identity).inserted {
            repeats[identity] = (self.measure(node).size, self.sizes[identity]?.text ?? 0)
            return
        }
        for child in node.children {
            self.findRepeats(child, &repeats)
        }
    }

    /**
     Returns an expression where each part named in `marked` is
     replaced by the mark `printedAboveMark`. The parts that are not
     named are kept, and only they are read.

     ```
     do shell script "new text" & big      →  do shell script "new text" & «value printed above»
     ```
     */
    func withoutRepeats(_ node: any Expr, _ marked: Set<ObjectIdentifier>) -> any Expr {
        if marked.contains(ObjectIdentifier(node)) {
            return Keyword(fallback: printedAboveMark)
        }
        node.rewriteChildren { $0.map { self.withoutRepeats($0, marked) } }
        return node
    }

    /** Adds a statement to the innermost open block, as it is. */
    func append(_ statement: any Stmt) {
        let current = self.blocks[self.blocks.count - 1]
        switch current.scope {
        case .root:
            self.handler.body.append(statement)
        case let .if(node):
            if current.inElse {
                node.else.append(statement)
            } else {
                node.then.append(statement)
            }
        case let .repeat(node):
            node.body.append(statement)
        case let .try(node):
            if current.inElse {
                node.errorBody.append(statement)
            } else {
                node.body.append(statement)
            }
        case let .tell(node):
            node.body.append(statement)
        case let .consider(node):
            node.body.append(statement)
        case let .timeout(node):
            node.body.append(statement)
        case let .transaction(node):
            node.body.append(statement)
        case .of:
            // Of/EndOf scopes an expression, not a source statement block.
            break
        }
    }

    /**
     Closes the innermost block and emits it into its parent.

     - An `of` scope becomes the expression `value of container`.
     - A `tell current application` block is not printed: its statements
       move to the parent block.
     */
    func closeTop() {
        let block = self.blocks.removeLast()
        switch block.scope {
        case let .of(container, stackBase):
            var value: any Expr = MissingLiteral()
            if self.stack.count > stackBase {
                value = self.pop()
                self.stack.removeSubrange(stackBase...)
            }
            self.push(Binary(op: .of, left: value, right: container))
            return
        case .try:
            break
        case let .tell(node):
            if self.isImplicitTell(node) {
                // These statements were counted when they were emitted.
                node.body.forEach { self.append($0) }
                return
            }
        default:
            break
        }
        if let statement = block.scope.statement {
            self.emit(statement)
        }
    }

    /**
     Closes every block that ends at or before `pc`.

     For an `if` block, reaching `elseAt` means: switch to the `else`
     part when the end is known, or close the block when there is no
     `else`.
     */
    func closeAt(_ pc: Int) {
        while self.blocks.count > 1 {
            let block = self.blocks[self.blocks.count - 1]
            switch block.scope {
            case .if:
                if block.endAt > 0 {
                    if pc >= block.endAt {
                        self.flushPendingExpression()
                        self.closeTop()
                        continue
                    }
                    if pc >= block.elseAt {
                        block.inElse = true
                    }
                } else if pc >= block.elseAt {
                    self.flushPendingExpression()
                    self.closeTop()
                    continue
                }
            case .repeat, .consider, .try:
                if block.endAt > 0, pc >= block.endAt {
                    self.flushPendingExpression()
                    self.closeTop()
                    continue
                }
            default:
                break
            }
            break
        }
    }

    /**
     Emits what is left on the stack before a block closes:

     - with a pending target, the top value is assigned to it (a script
       object is a statement that names its variable itself:
       `script s` … `end script`);
     - with the parts of a pattern, the top value is assigned to the
       pattern;
     - if not, a value pushed inside the block and still there is a
       statement of its own: `"a"` in `if x then "a"`.
     */
    func flushPendingExpression() {
        if self.stack.isEmpty {
            return
        }
        if self.emitPatternAssignment() {
            return
        }
        if self.pending != nil {
            self.assignPending(self.read(self.pop()))
            return
        }
        let base = self.blocks[self.blocks.count - 1].stackBase
        if self.stack.count > base {
            let values = self.stack[base...]
            self.stack.removeSubrange(base...)
            for value in values {
                self.emit(Expression(value: self.read(value)))
            }
        }
    }

    /**
     Emits the statement that gives `value` to the pending target:

     ```
     set y to x          a plain value
     copy x to y         a value that `Clone` copied
     script s … end      a script object, which names its variable itself
     ```

     A statement ends with `StoreResult`, but the last one of a block,
     or of a handler, does not: the end of the block comes first. Every
     place that ends a statement goes through here, so that the three
     forms are read the same way everywhere.
     */
    func assignPending(_ value: any Expr) {
        if let object = value as? ScriptObject {
            self.emit(Expression(value: object))
        } else if let copied = value as? CopyExpr {
            self.emit(Copy(source: copied.value, target: self.pending))
        } else {
            self.emit(SetStmt(target: self.pending, value: value))
        }
        self.pending = nil
    }

    /**
     Opens a block. The size of the stack is kept: a value above it
     when the block closes was pushed by a statement of the block.

     A block inside `blockDepthLimit` others is not opened: its
     statements go to the block around it. Real code is never that
     deep, but one byte opens a block, and what walks the tree calls
     itself once for each level.
     */
    func open(_ block: Block) {
        if self.blocks.count > self.blockDepthLimit {
            if !self.reportedTooDeep {
                self.reportedTooDeep = true
                self.decompiler.report(self.function.offset, "blocks are nested deeper than \(self.blockDepthLimit) levels: the inner ones are not opened")
            }
            return
        }
        block.stackBase = self.stack.count
        self.blocks.append(block)
    }

    /** Completes the `and` / `or` operations whose right side ends at `pc`. */
    func closeLogic(_ pc: Int) {
        while let item = logic.last, pc >= item.end {
            self.logic.removeLast()
            let right = self.read(self.pop())
            self.push(Binary(op: item.op, left: item.left, right: right))
        }
    }

    /**
     The words to use for the instruction being read. Inside
     `tell application "X"` the words of X are known, and come first;
     inside `tell current application`, no application is told. A
     `tell` to `me` or to an object, like `tell window 1`, changes
     nothing, and so does a `tell` that the compiler added by itself.
     The printer follows the same rule: see `SourceFormatter.inside(_:)`.
     */
    var terms: Registry? {
        guard let all = self.decompiler.scriptTerms else {
            return nil
        }
        func scoped(_ application: ApplicationName) -> Registry {
            if let known = self.decompiler.scopedTerms[application] {
                return known
            }
            let scoped = all.scoped(to: application)
            self.decompiler.scopedTerms[application] = scoped
            return scoped
        }
        for block in self.blocks.reversed() {
            // `using terms from` lasts to the end of the block it is in.
            if let inner = self.usingTermsScopes.last(where: { $0.block === block }) {
                return scoped(inner.application)
            }
            guard
                let node = block.scope.tellNode,
                !self.isImplicitTell(node)
            else {
                continue
            }
            if let application = node.target?.applicationName {
                return scoped(application)
            }
            if node.target is CurrentApplication {
                return all
            }
        }
        return all
    }

    /**
     True for a `tell current application` that the compiler added by
     itself around a command of a scripting addition. It is not printed.
     */
    func isImplicitTell(_ node: Tell) -> Bool {
        self.decompiler.usesScriptingAdditions && node.target is CurrentApplication
    }

    /**
     Puts an expression on the stack.

     Damaged bytecode can use one expression twice in a larger one, and
     do it again with the result:

     ```
     Dup, Add        x + x
     Dup, Add        (x + x) + (x + x)
     Dup, Add        …
     ```

     The tree stays small, because the two sides are the same node, but
     its printed form doubles at each step. So the size of an expression
     is compared with the number of nodes this function has made. An
     expression of real code is never much larger than that. One that
     is, is replaced by `«expression too large»`.

     The same holds for text. `Dup, Concatenate` on a text of one
     megabyte gives a gigabyte after ten steps, with eleven nodes. So
     the text of an expression is compared with the text of all the
     nodes, each one counted once.

     Damaged bytecode can also put one operation inside the other
     without end: a megabyte of `Not` is a million levels. The code
     that walks the tree calls itself once for each level, so an
     expression deeper than `expressionDepthLimit` is replaced by
     `«expression too deep»`.
     */
    func push(_ value: any Expr) {
        let measure = self.measure(value)
        if measure.size > 2 * self.sizes.count + 1024 || self.text(of: value) > 2 * self.distinctText + 4096 {
            self.reportTooLarge()
            self.stack.append(Keyword(fallback: "«expression too large»"))
            return
        }
        if measure.depth > self.expressionDepthLimit {
            self.decompiler.report(self.function.offset, "an expression is nested deeper than \(self.expressionDepthLimit) levels: it is not printed")
            self.stack.append(Keyword(fallback: "«expression too deep»"))
            return
        }
        self.stack.append(value)
    }

    /**
     Returns the number of nodes an expression prints: itself and all
     that is under it, where a node used twice counts twice.
     */
    func size(of node: any Expr) -> Int {
        self.measure(node).size
    }

    /**
     Returns the size of an expression (see `size(of:)`) and its depth:
     1 for a node with nothing inside it.

     The two are kept, with the node, so that a later call is
     immediate. The children of a node are always seen before it.
     */
    func measure(_ node: any Expr) -> (size: Int, depth: Int) {
        if let known = sizes[ObjectIdentifier(node)] {
            return (known.size, known.depth)
        }
        var size = 1
        var depth = 0
        // The bytes that the node itself prints as text or as data.
        let own = switch node {
        case let node as StringLiteral: node.value.utf8.count
        case let node as RawDataLiteral: 2 * node.data.count
        case let node as OpaqueLiteral: 2 * node.data.count
        default: 0
        }
        var text = own
        for child in node.children {
            let inner = self.measure(child)
            size = size.addingSaturating(inner.size)
            depth = max(depth, inner.depth)
            text = text.addingSaturating(self.text(of: child))
        }
        self.distinctText = self.distinctText.addingSaturating(own)
        self.sizes[ObjectIdentifier(node)] = (node, size, depth + 1, text)
        return (size, depth + 1)
    }

    /**
     Returns the bytes of text and data that an expression prints: its
     own and those of all that is under it, where a node used twice
     counts twice.
     */
    func text(of node: any Expr) -> Int {
        _ = self.measure(node)
        return self.sizes[ObjectIdentifier(node)]?.text ?? 0
    }

    func reportTooLarge() {
        if !self.reportedTooLarge {
            self.reportedTooLarge = true
            self.decompiler.report(self.function.offset, "the handler repeats one expression too many times: a part is not printed")
        }
    }

    /**
     Removes and returns the top expression.

     On an empty stack it returns `missing value` and sets `underflow`, so
     the caller can report the problem after the instruction.
     */
    func pop() -> any Expr {
        if self.stack.isEmpty {
            self.underflow = true
            return MissingLiteral()
        }
        return self.stack.removeLast()
    }

    /** Pops a number literal and returns it as a count (0 for anything else). */
    func popNumber() -> Int {
        let value = self.pop()
        if let number = value as? NumberLiteral {
            if number.isReal {
                return Int(exactly: number.real.rounded(.towardZero)) ?? 0
            }
            return Int(number.integer)
        }
        return 0
    }

    func variable(_ index: Int) -> String {
        if index >= 0, index < self.variables.count {
            return self.variables[index]
        }
        return "var_\(index)"
    }

    func literal(_ index: Int) -> any Expr {
        guard let value = function.literal(index) else {
            return Variable(name: "literal_\(index)")
        }
        if case let .typedData(opaque) = value {
            self.decompiler.report(self.function.offset, "unresolved runtime data type \(opaque.type)")
        }
        return self.decompiler.literal(value, in: self.function.offset)
    }

    /** Emits the top of the stack as a statement, or as a pending assignment. */
    func flushExpression() {
        if self.stack.isEmpty || self.emitPatternAssignment() {
            return
        }
        let value = self.read(self.pop())
        if self.pending != nil {
            self.assignPending(value)
            return
        }
        self.emit(Expression(value: value))
    }

    /**
     Returns the innermost open block of one kind, with its node.

     `node` reads the node from the scope of a block, and gives `nil`
     for a block of another kind: `current(\.repeatNode)`.
     */
    func current<Node>(_ node: (Scope) -> Node?) -> (block: Block, node: Node)? {
        for block in self.blocks.dropFirst().reversed() {
            if let found = node(block.scope) {
                return (block, found)
            }
        }
        return nil
    }

    /** Closes blocks from the innermost one up to and including `target`. */
    func closeThrough(_ target: Block) {
        while self.blocks.count > 1 {
            let current = self.blocks[self.blocks.count - 1]
            self.closeTop()
            if current === target {
                return
            }
        }
    }

    /** Pops up to `count` expressions and returns them in push order. */
    func popMany(_ count: Int) -> [any Expr] {
        let count = min(max(count, 0), stack.count)
        let start = self.stack.count - count
        let out = Array(stack[start...])
        self.stack.removeSubrange(start...)
        return out
    }

    /**
     Returns the name of variable `index` in an enclosing scope.

     `depth` 1 is the nearest enclosing scope. When that scope has no such
     index, outer scopes are tried.
     */
    func parentVariable(_ depth: Int, _ index: Int) -> String {
        self.parentDepth = max(self.parentDepth, depth)
        let start = max(depth - 1, 0)
        // A depth past the last scope comes from damaged bytecode: the
        // fallback name is used.
        for scope in self.parentScopes.dropFirst(start) where index >= 0 && index < scope.count {
            return scope[index]
        }
        return "parent_var_\(index)"
    }

    /** Returns the name held by literal `index`, or an empty string. */
    func literalName(_ index: Int) -> String {
        guard let value = function.literal(index) else {
            return ""
        }
        if let bytes = value.bytes ?? value.binding?.value.bytes {
            return String(decoding: bytes, as: UTF8.self)
        }
        return ""
    }

    /** Returns the global named by literal `index`: a variable or a literal. */
    func global(_ index: Int) -> any Expr {
        guard let value = function.literal(index) else {
            return Variable(name: "global_\(index)")
        }
        if let raw = value.bytes {
            let name = String(decoding: raw, as: UTF8.self)
            if self.knownGlobals.insert(name).inserted {
                self.globalNames.append(name)
            }
            return Variable(name: name)
        }
        return self.decompiler.literal(value, in: self.function.offset)
    }

    /**
     Returns the local variable `index` as an expression, and notes its
     name in `localNames` when the function has a real name for it.
     */
    func local(_ index: Int) -> Variable {
        let name = self.variable(index)
        if self.function.variables.indices.contains(index), self.function.variables[index].bytes != nil, self.knownLocals.insert(name).inserted {
            self.localNames.append(name)
        }
        return Variable(name: name)
    }
}
