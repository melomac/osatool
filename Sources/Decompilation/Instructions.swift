import AST
import Bytecode
import Extensions
import FAS
import Model
import Terminology

extension State {
    /**
     Applies one instruction to the state.

     Every opcode has one line here. An opcode that needs more than a
     few lines has its own method, below.

     - Throws: `ScriptError` for a byte that has no operation.
     */
    func instruction(_ inst: Instruction) throws {
        switch inst.opcode {
        // Values
        case let .pushLiteral(index): self.push(self.literal(index))
        case let .pushInteger(value): self.push(NumberLiteral(integer: Int64(value)))
        case .pushTrue: self.push(BooleanLiteral(value: true))
        case .pushFalse: self.push(BooleanLiteral(value: false))
        case .pushEmpty: self.push(List())
        case .pushIt: self.push(It())
        case .pushMe: self.push(Me())
        // A marker that is not put on the stack: the instruction after it (`Pop`, `Error`) sees it in `previous`.
        case .pushUndefined: break
        case let .pushVariable(index): self.push(self.local(index))
        case let .popVariable(index): self.pending = self.local(index)
        case let .pushGlobal(literal): self.push(self.global(literal))
        case let .popGlobal(literal): self.pending = self.global(literal)
        case let .pushParentVariable(depth, index): self.push(Variable(name: self.parentVariable(depth, index)))
        case let .popParentVariable(depth, index): self.pending = Variable(name: self.parentVariable(depth, index))
        case .dup: self.duplicate()
        case .gcSwap: self.swap()
        case .pop: self.discard()
        case .makeVector, .makeList: self.makeList()
        case .makeRecord: self.makeRecord()
        case let .makeObjectAlias(form): self.makeSpecifier(form)
        case let .makeComp(index): self.makeComparison(index)
        case .clone: self.push(CopyExpr(value: self.read(self.pop())))
        case .objectAliasQuote: self.push(Reference(value: self.pop()))
        case let .defineActor(literal): self.defineScriptObject(literal)
        // Operators
        case let .binary(op): self.binary(BinaryKind(op))
        case .coerce: self.coerce()
        case .negate: self.push(Unary(op: .negate, value: self.pop()))
        case .not: self.push(Unary(op: .not, value: self.pop()))
        case let .and(end): self.logic.append(LogicState(op: .and, left: self.read(self.pop()), end: end))
        case let .or(end): self.logic.append(LogicState(op: .or, left: self.read(self.pop()), end: end))
        // Statements
        case .setData: self.pending = self.pop()
        case .copyData: self.copyData()
        case .storeResult: self.storeResult()
        case .return: self.returnValue(isLast: inst.offset + inst.length >= self.function.code.count)
        case .error: self.raiseError()
        case .exit: self.emit(ExitRepeat())
        // Calls
        case let .messageSend(literal): self.message(literal, false)
        case let .positionalMessageSend(literal): self.message(literal, true)
        case let .continue(literal): self.continueCall(literal, false)
        case let .positionalContinue(literal): self.continueCall(literal, true)
        // Blocks
        case let .testIf(elseAt): self.open(Block(.if(If(condition: self.read(self.pop()))), elseAt: elseAt))
        case let .jump(target): self.jump(to: target, from: inst.offset)
        case let .linkRepeat(end): self.open(Block(.repeat(Repeat(kind: .forever)), endAt: end))
        case .repeatNTimes: self.repeatTimes()
        case .repeatWhile: self.repeatCondition(.while)
        case .repeatUntil: self.repeatCondition(.until)
        case let .repeatInCollection(variable): self.repeatInCollection(variable)
        case let .repeatInRange(variable): self.repeatInRange(variable)
        case .tell: self.open(Block(.tell(Tell(target: self.pop()))))
        case .endTell: self.endTell()
        case let .consider(end): self.beginConsider(end: end)
        case .endConsider: self.end(\.considerNode)
        case .beginTimeout: self.open(Block(.timeout(Timeout(seconds: self.read(self.pop())))))
        case .endTimeout: self.end(\.timeoutNode)
        case let .beginTransaction(end): self.open(Block(.transaction(Transaction()), endAt: end))
        case .endTransaction: self.endTransaction()
        case let .errorHandler(handler): self.open(Block(.try(Try()), elseAt: handler))
        case let .endErrorHandler(end): self.endErrorHandler(end: end)
        case let .handleError(message, number): self.handleError(message, number)
        case let .of(end): self.beginOf(end: end)
        case .endOf: self.endOf()
        // An empty line that ends a block: see `Blank`.
        case .getResult: self.emit(Blank())
        // Opcodes that leave no trace in the source. `PushNext` gives a
        // value used at run time by the `Continue` that follows it.
        case .pushNext, .endDefineActor, .defineProcedure, .defineClosure, .matchLiteral:
            break
        case let .defineProperty(literal): self.defineProperty(literal)
        case .getData: self.getData()
        case .invalid:
            throw ScriptError("unsupported opcode \(inst.mnemonic) (0x\(inst.byte.hex(width: 2)))")
        }
    }

    // MARK: - Values

    func duplicate() {
        if let top = stack.last {
            self.push(top)
        }
    }

    func swap() {
        if self.stack.count >= 2 {
            self.stack.swapAt(self.stack.count - 1, self.stack.count - 2)
        }
    }

    /**
     Removes the top of the stack. A `Pop` right after `PushUndefined`
     removes that marker, which is not on the stack.

     Inside a handler, `using terms from` leaves its application, pushed
     and removed at once. Nothing says where the block ends:

     ```
     using terms from application "Finder"       PushLiteral, Pop
     using terms from scripting additions        PushIt, PushLiteral 'osax', MakeObjectAlias every, Pop
     ```
     */
    func discard() {
        if self.previous == .pushUndefined {
            return
        }
        if self.pending == nil, let top = self.stack.last, let block = self.usingTerms(top) {
            _ = self.pop()
            if let application = top.applicationName {
                self.usingTermsScopes.append((self.blocks[self.blocks.count - 1], application))
            }
            self.emit(block)
            return
        }
        if let target = self.pending, self.takePatternPart(target) {
            // One name of `set {a, b} to …` is set: see `PatternPart`.
            self.pending = nil
        } else if !self.stack.isEmpty {
            let top = self.pop()
            // `{name} of x`: `x` is removed once its parts are made (see `sharedContainer`).
            if let part = self.stack.last as? Specifier, part.container === top {
                self.sharedContainerSeen = top
            }
        }
    }

    /**
     Returns the `using terms from` block that the value on top of the
     stack opens when `Pop` removes it now, or `nil` (see `discard`).
     The statements of the block are put in it later: see
     `Decompiler.nestUsingTerms`.
     */
    func usingTerms(_ top: any Expr) -> UsingTerms? {
        if case .pushLiteral = self.previous, top.applicationName != nil {
            return UsingTerms(application: top)
        }
        if self.previous == .makeObjectAlias(form: .every), let node = top as? Specifier, node.container is It,
           (node.object as? Keyword)?.code == .four("osax")
        {
            return UsingTerms()
        }
        return nil
    }

    /**
     Pops a count, then that many values, and returns them in push
     order.

     The count is a value of the code, and damaged code can hold any
     number there. A negative count is treated as zero. A count larger
     than the stack is an underflow: only what the stack has is taken,
     so that a count of a billion does not ask for a billion places.
     */
    func popCounted() -> [any Expr?] {
        let count = max(popNumber(), 0)
        if count > self.stack.count {
            self.underflow = true
        }
        return self.popMany(count)
    }

    func makeList() {
        let elements = self.popCounted().map { $0.map(self.read) }
        self.push(self.sharedContainer(elements) ?? List(elements: elements))
    }

    /**
     Reads `{name, size} of x` back from its list.

     The compiler makes `{name of x, size of x}` from it, with `x`
     worked out once and used for each item (`Dup`). So the items of
     the list have the very same object as their container, which two
     references written one by one never have.

     - Returns: `nil` when the list is not of this kind.
     */
    func sharedContainer(_ elements: [any Expr?]) -> (any Expr)? {
        let parts = elements.compactMap { $0 as? Specifier }
        guard
            !parts.isEmpty,
            parts.count == elements.count,
            let container = parts[0].container,
            parts.allSatisfy({ $0.container === container }),
            // One item alone shares nothing: the container was seen being removed.
            parts.count > 1 || self.sharedContainerSeen === container
        else {
            return nil
        }
        let names = parts.map { Specifier(kind: $0.kind, object: $0.object, from: $0.from, to: $0.to, keyName: $0.keyName) }
        return Specifier(kind: .property, object: List(elements: names), container: container)
    }

    /**
     Notes that the value on top of the stack is read (`GetData`).

     For a reference, this is what `get` does in the source, so the
     reference becomes `get reference`. The compiler also reads a
     reference by itself in some places; there `read` takes the `get`
     away again.
     */
    func getData() {
        guard let top = self.stack.last else {
            return
        }
        let isReference = top is Specifier || top is Whose || top is GetExpr || (top as? Binary)?.op == .of
        if isReference {
            self.stack[self.stack.count - 1] = GetExpr(value: top)
        }
    }

    /**
     Returns a value as it is where the compiler reads a reference by
     itself: one `get` around it is not from the source.

     These places were found with the compiler, by writing `item 1 of x`
     and `(get item 1 of x)` in each one and comparing the code:

     ```
     read by the compiler            not read: `get` is from the source
     an item of a list, a record     an operand of + & = < contains, of `as`
     an operand of `and`, `or`       an argument of a handler or a command
     an index: item (…) of x         a container: item 1 of (…)
     if, repeat … times, while       repeat with i in (…)
     return, a whole statement       tell (…), error (…)
     set x to …, copy … to x         (there `get` reads a second time)
     ```
     */
    func read(_ value: any Expr) -> any Expr {
        (value as? GetExpr)?.value ?? value
    }

    /** Builds a record from labels and values pushed in turn. */
    func makeRecord() {
        let values = self.popCounted()
        let record = Record()
        var index = 0
        while index + 1 < values.count {
            record.fields.append(RecordField(label: values[index], value: values[index + 1].map(self.read)))
            index += 2
        }
        self.push(record)
    }

    /**
     Rebuilds a script object defined inside a handler. Its name is the
     pending assignment target, or the nearest name on the stack.
     */
    func defineScriptObject(_ literal: Int) {
        let raw = function.literal(literal)?.vector
        var name: String?
        if let variable = pending as? Variable {
            name = variable.name
            self.pending = nil
        } else {
            while !self.stack.isEmpty, name == nil {
                let nameExpr = self.pop()
                if let text = nameExpr as? StringLiteral {
                    name = text.value
                } else if let variable = nameExpr as? Variable {
                    name = variable.name
                }
            }
        }
        if let raw {
            self.push(self.decompiler.actor(raw, name, [NameScope(self.variables)] + self.parentScopes))
        } else {
            self.push(ScriptObject(name: name ?? ""))
        }
    }

    /**
     `property parent : x` of a script object defined inside a handler.
     The value is on the stack, and the literal is the code `pare`. The
     other properties are variables of the object: see
     `Decompiler.actor`.
     */
    func defineProperty(_ literal: Int) {
        guard !self.stack.isEmpty else {
            return
        }
        let value = self.read(self.pop())
        var name = self.function.literal(literal).literal
        if let keyword = name as? Keyword, keyword.code == .four("pare") {
            name = Keyword(code: .four("pare"), fallback: "parent")
        }
        self.emit(SetStmt(target: name, value: value))
    }

    // MARK: - Operators

    func binary(_ kind: BinaryKind) {
        let right = self.pop()
        let left = self.pop()
        self.push(Binary(op: kind, left: left, right: right))
    }

    func coerce() {
        let right = self.pop()
        let left = self.pop()
        self.push(Coerce(value: left, type: right))
    }

    // MARK: - Statements

    func copyData() {
        let target = self.pop()
        let source = self.pop()
        self.emit(Copy(source: source, target: target))
    }

    /**
     Ends a statement: the value on the stack is assigned to the pending
     target, or becomes a statement of its own.
     */
    func storeResult() {
        if self.stack.isEmpty {
            return
        }
        var value = self.pop()
        // The compiler sometimes pushes the value twice.
        if let top = stack.last, top === value {
            _ = self.pop()
        }
        if let assignment = self.pending == nil ? self.patternAssignment(of: value) : nil {
            self.emit(assignment)
            return
        }
        value = self.read(value)
        if self.pending != nil || value is ScriptObject {
            self.assignPending(value)
        } else {
            self.emit(Expression(value: value))
        }
    }

    /**
     - `isLast`: the instruction is the last one of the function. The
       compiler ends every function with a `Return`: that one is not a
       `return` of the source.
     */
    func returnValue(isLast: Bool) {
        // `set {a, b} to f()` as the last statement: the value of the
        // parts is still on the stack, and it is the value of the pattern.
        if self.emitPatternAssignment() {
            return
        }
        if self.pending != nil, !self.stack.isEmpty {
            self.assignPending(self.read(self.pop()))
        } else if !self.stack.isEmpty {
            let value = self.read(self.pop())
            if !isLast {
                self.emit(Return(value: value, explicit: true))
            } else {
                self.emit(Expression(value: value))
            }
        } else if !isLast {
            // A valueless return before the function epilogue is explicit.
            // The final valueless Return is compiler-generated and omitted.
            self.emit(Return(explicit: true))
        }
    }

    /**
     Builds an `error` statement. The stack holds `me`, then a label
     and a value for each part, their count, and the message:

     ```
     error "text" number 42      me | 'errn' 42 | 2 | "text"
     error number -128           me | 'errn' -128 | 2 | (no message)
     ```

     Without a message the compiler writes `PushUndefined`, which is
     not on the stack.
     */
    func raiseError() {
        var message: any Expr?
        if self.previous != .pushUndefined {
            message = self.pop()
        }
        let count = self.popNumber()
        let values = self.popMany(count)
        if !self.stack.isEmpty {
            _ = self.pop()
        }
        var args: [any Argument] = message.map { [DirectArgument(value: $0)] } ?? []
        args.append(contentsOf: (self.decompiler.options.terms?.command(EventCode()) ?? Command()).arguments(values))
        self.emit(ErrorStmt(arguments: args))
    }

    // MARK: - Blocks

    /** A forward jump inside an `if` block gives the end of the block: an `else` follows. */
    func jump(to target: Int, from offset: Int) {
        guard self.blocks.count > 1 else {
            return
        }
        let block = self.blocks[self.blocks.count - 1]
        if block.scope.ifNode != nil, target > offset {
            self.flushPendingExpression()
            block.endAt = target
        }
    }

    func repeatTimes() {
        if let (_, node) = self.current(\.repeatNode) {
            node.kind = .times
            _ = self.pop()
            node.times = self.read(self.pop())
        }
    }

    func repeatCondition(_ kind: RepeatKind) {
        if let (_, node) = self.current(\.repeatNode) {
            node.kind = kind
            node.condition = self.read(self.pop())
        }
    }

    func repeatInCollection(_ variable: Int) {
        if let (_, node) = self.current(\.repeatNode) {
            node.kind = .in
            node.variable = self.variable(variable)
            _ = self.pop()
            _ = self.pop()
            node.collection = self.pop()
        }
    }

    func repeatInRange(_ variable: Int) {
        if let (_, node) = self.current(\.repeatNode) {
            node.kind = .range
            node.variable = self.variable(variable)
            node.by = self.read(self.pop())
            node.to = self.read(self.pop())
            node.from = self.read(self.pop())
        }
    }

    /** Closes the innermost open block of one kind, and the blocks inside it. */
    func end<Node>(_ node: (Scope) -> Node?) {
        if let (block, _) = self.current(node) {
            self.flushPendingExpression()
            self.closeThrough(block)
        }
    }

    func endTell() {
        if let (block, node) = self.current(\.tellNode) {
            // The value of an implicit tell stays on the stack: the
            // expression around it uses it.
            if !self.isImplicitTell(node) {
                self.flushPendingExpression()
            }
            self.closeThrough(block)
        }
    }

    /**
     Opens a `considering` or `ignoring` block. The compiler pushes two
     lists of attributes: the considered ones, then the ignored ones.
     */
    func beginConsider(end: Int) {
        let terms = self.decompiler.options.terms
        let ignored = self.pop().considerationNames(terms)
        var considered = self.pop().considerationNames(terms)
        if considered.isEmpty, ignored.isEmpty {
            considered = ["case"]
        }
        self.open(Block(.consider(Considering(options: considered, ignored: ignored)), endAt: end))
    }

    func endTransaction() {
        if let (block, _) = self.current(\.transactionNode) {
            self.flushPendingExpression()
            self.closeThrough(block)
        }
    }

    /** The end of the `try` part: what follows is the `on error` part. */
    func endErrorHandler(end: Int) {
        if let (block, _) = self.current(\.tryNode) {
            self.flushExpression()
            block.inElse = true
            block.endAt = end
        }
    }

    /**
     Reads the `on error` line. The first literal is the name of the
     variable for the message. The second one is a chain with one link
     for each other part, in the order of the source:

     ```
     on error msg number n from f       'errn' → "n",  'erob' → "f"
     on error number -128               'errn' → -128
     ```
     */
    func handleError(_ message: Int, _ parts: Int) {
        guard let (_, node) = self.current(\.tryNode) else {
            return
        }
        node.errorName = self.literalName(message)
        var seen = Visited()
        var link = self.function.literal(parts)?.binding
        while let binding = link, seen.enter(.binding(binding)) {
            // A link without a known code is the number: the first part there was.
            let code = binding.key.object?.constant.map { Code4(rawValue: UInt32(truncatingIfNeeded: $0)) }
            if let label = code.flatMap({ ErrorLabel(code: $0) }) ?? (node.parameters.isEmpty ? .number : nil) {
                if let name = binding.value.bytes {
                    node.parameters.append(ErrorParameter(label, Variable(name: String(decoding: name, as: UTF8.self))))
                } else if !binding.value.isNull {
                    node.parameters.append(ErrorParameter(label, self.decompiler.literal(binding.value, in: self.function.offset)))
                }
            }
            link = binding.next.binding
        }
    }

    func beginOf(end: Int) {
        let container = self.pop()
        self.blocks.append(Block(.of(container: container, stackBase: self.stack.count), endAt: end))
    }

    /** Closes an `of` scope: the value on top becomes `value of container`. */
    func endOf() {
        guard let (block, scope) = self.current(\.ofScope) else {
            return
        }
        let value = self.pop()
        while self.blocks.count > 1, self.blocks[self.blocks.count - 1] !== block {
            self.closeTop()
        }
        if self.blocks.count > 1 {
            self.blocks.removeLast()
        }
        if self.stack.count > scope.stackBase {
            self.stack.removeSubrange(scope.stackBase...)
        }
        self.push(Binary(op: .of, left: value, right: scope.container))
    }
}
