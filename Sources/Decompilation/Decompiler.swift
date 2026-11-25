import AST
import Bytecode
import Extensions
import FAS
import Model
import Terminology

/** How `run` rebuilds the syntax tree. */
package struct RebuildOptions {
    /** When true, the first problem stops the work with an error. */
    package var strict: Bool
    /** The words of the language and of the applications. Without them, codes are printed raw. */
    package var terms: Registry?

    package init(strict: Bool = false, terms: Registry? = nil) {
        self.strict = strict
        self.terms = terms
    }
}

/** What `run` gives: the syntax tree, and the problems met on the way. */
package struct RebuiltScript {
    package var script: Script
    package var diagnostics: [Diagnostic]
}

/**
 Rebuilds the syntax tree of a script.

 The entries of the script table are read in order, which is the order
 of the source:

 - a plain value becomes a `use` line or a property;
 - a script object becomes a `script … end script`;
 - a function becomes a handler.

 A handler is rebuilt by running its bytecode on a symbolic stack: every
 instruction pushes or pops expressions instead of values, and
 instructions that end a statement emit a statement node.

 - Throws: in strict mode, the first problem of a function of the
   script table.
 */
package func run(_ script: CompiledScript, options: RebuildOptions) throws -> RebuiltScript {
    let decompiler = Decompiler(script: script, options: options)
    let output = decompiler.output
    let table = script.table
    // The `use` lines are read first: they change how a handler is read.
    for entry in table.entries where entry.kind.isValue && entry.name?.isConstant("pimr") == true {
        decompiler.extractUses(entry)
    }
    decompiler.scriptTerms = options.terms?.using(output.uses.compactMap(\.applicationName), scriptingAdditions: output.uses.loadScriptingAdditions)
    let rootScope = NameScope(table.names.enumerated().map { $0.element.identifier(or: "parent_var_\($0.offset)") })
    // A parent that no entry defines: a script loaded when the source was compiled.
    for object in table.parentObjects {
        output.members.append(.object(decompiler.scriptObject(object, [rootScope])))
    }
    for entry in table.entries {
        switch entry.kind {
        case .value:
            decompiler.rootValue(entry)
        case let .scriptObjects(tables):
            for object in tables {
                output.members.append(.object(decompiler.scriptObject(object, [rootScope])))
            }
        case let .function(function):
            do {
                let handler = try decompiler.function(function, [rootScope], isTopLevel: true)
                decompiler.nameAfterEntry(handler, entry, function)
                // The statements at the top level of a script are its run
                // handler, and the compiler puts it after everything else.
                // A run handler found there is printed that way.
                if handler.isRunHandler, handler.parameters.isEmpty, entry.offset == table.entries.last?.offset {
                    handler.isImplicit = true
                }
                output.members.append(.handler(handler))
            } catch {
                if options.strict {
                    throw error
                }
                decompiler.report(function.offset, error.message)
            }
        }
    }
    if let line = decompiler.globalsLine(for: output.members, of: table, names: rootScope.names) {
        output.members.insert(line, at: output.members.firstIndex { $0.use == nil } ?? output.members.count)
    }
    return RebuiltScript(script: output, diagnostics: decompiler.allDiagnostics)
}

/**
 The names of one table around a function, in the order of the table:
 its properties, its handlers and its script objects. A handler reaches
 them by their place (`PushParentVariable`), and asks whether one of its
 own variables has the name of one of them (see `declarations`).

 The set of the names is made once, on the first question. Making it
 again for each handler took a time that grew with the square of their
 number: 7 seconds for a script with 4,000 handlers.
 */
final class NameScope: ExpressibleByArrayLiteral {
    let names: [String]
    private lazy var set = Set(self.names)

    init(_ names: [String]) {
        self.names = names
    }

    convenience init(arrayLiteral elements: String...) {
        self.init(elements)
    }

    var count: Int {
        self.names.count
    }

    subscript(index: Int) -> String {
        self.names[index]
    }

    func contains(_ name: String) -> Bool {
        self.set.contains(name)
    }
}

final class Decompiler {
    let script: CompiledScript
    let options: RebuildOptions
    let output = Script()
    var diagnostics: [Diagnostic] = []
    /** The number of diagnostics that were not kept: see `add`. */
    var diagnosticsLeftOut = 0
    /** How many times each message was given, for the messages that are kept. */
    var diagnosticCounts: [String: Int] = [:]
    /** The number of instructions that can still be read: see `maximumInstructions`. */
    var instructionBudget = maximumInstructions
    /**
     True when the script has `use scripting additions`. The compiler
     then puts each command of a scripting addition inside its own
     `tell current application`, which is not in the source.
     */
    var usesScriptingAdditions = false
    /**
     What each handler uses, by handler: its globals, its own
     variables, and how many tables up its farthest name is (0 for no
     such name). See `globalsLine`.
     */
    var handlerUse: [ObjectIdentifier: (globals: [String], locals: [String], parentDepth: Int)] = [:]
    /**
     The initializers of the script objects being rebuilt, one inside
     the other, and how many more can be rebuilt: see `actor`.
     */
    var actorsBeingRebuilt: Set<ObjectIdentifier> = []
    var actorBudget = maximumScriptObjectsInHandlers
    var reportedActorLimit = false
    /** True once a diagnostic says that the script has too many instructions. */
    var reportedInstructionLimit = false
    /** The bytes of text that the statements of the script print again: see `State.emit`. */
    var repeatedText = 0
    /** True once a diagnostic says that statements are left out for the text they print again. */
    var reportedRepeatedText = false
    /**
     The words known in the whole script: those of `options.terms`, and
     those of each application of a `use application` line.
     */
    var scriptTerms: Registry?
    /** The words to use inside a `tell` block, by application: see `State.terms`. */
    var scopedTerms: [ApplicationName: Registry] = [:]
    /** Converts the stored values, and counts how many can still be converted: see `literal(_:in:)`. */
    var literalPath = LiteralPath()

    init(script: CompiledScript, options: RebuildOptions) {
        self.script = script
        self.options = options
    }

    /**
     Records a problem of the function in slot `function`.

     - `offset`: the position of the instruction that is the cause, when
       there is one.
     */
    func report(_ function: Int, at offset: Int? = nil, _ message: String) {
        self.add(Diagnostic(stage: .decompile, function: function, offset: offset, message: message))
    }

    /**
     Keeps a diagnostic, unless there are too many: the same message is
     kept `maximumRepeatedDiagnostics` times, and `maximumDiagnostics`
     are kept in all. The others are counted: `allDiagnostics` ends
     with their number.

     Damaged code can give the same diagnostic for each of its bytes. A
     megabyte of them took 600 MB, and nobody reads a million lines.
     The limit is for each message, so that a problem of another kind
     is still told after them.
     */
    func add(_ diagnostic: Diagnostic) {
        guard self.diagnostics.count < maximumDiagnostics else {
            self.diagnosticsLeftOut += 1
            return
        }
        let count = self.diagnosticCounts[diagnostic.message, default: 0] + 1
        self.diagnosticCounts[diagnostic.message] = count
        if count <= maximumRepeatedDiagnostics {
            self.diagnostics.append(diagnostic)
        } else {
            self.diagnosticsLeftOut += 1
        }
    }

    /** The diagnostics that were kept, and one more that tells how many were not. */
    var allDiagnostics: [Diagnostic] {
        guard self.diagnosticsLeftOut > 0 else {
            return self.diagnostics
        }
        let message = "\(self.diagnosticsLeftOut) more problems are not listed: "
            + "a problem is listed \(maximumRepeatedDiagnostics) times at most, and \(maximumDiagnostics) problems in all"
        return self.diagnostics + [Diagnostic(stage: .decompile, message: message)]
    }

    /**
     Converts a stored value (see `LiteralPath`). Every conversion of
     one decompilation takes from the same budgets, so a damaged file
     cannot make the output grow without end.

     - `slot`: the entry or the function the value belongs to. It is
       named in the diagnostic, the first time a value is not written
       in full.
     */
    func literal(_ value: Value?, in slot: Int) -> any Expr {
        let wasWhole = self.literalPath.cut == 0
        let result = self.literalPath.literal(value)
        if wasWhole, self.literalPath.cut > 0 {
            self.report(slot, "the script writes the same large values again and again: some are not printed in full")
        }
        return result
    }

    /**
     Reads one entry of the script table that is a plain value.

     The name of the entry tells what it is:

     - a plain identifier: a property, or `use Alias : script "Name"` when
       the value is a script library;
     - the code `pimr`: the list of `use` imports (read before, by `run`);
     - the code `pare`: `property parent : …`;
     - any other code: a property named with a word of the language or
       of an application, such as `property size : 3`.
     */
    func rootValue(_ entry: Entry) {
        guard
            let nameValue = entry.name,
            !nameValue.isConstant("pimr"),
            let property = self.property(entry, of: self.script.table)
        else {
            return
        }
        if property.keyword == nil, !nameValue.isConstant("pare"), let library = property.value as? ScriptLibrary {
            self.output.members.append(.use(Use(name: library.name, alias: property.name)))
            return
        }
        self.output.members.append(.property(property))
    }

    /**
     Rebuilds a script object found by `Model.normalize`, with the script
     objects defined inside it.

     An entry of the table is one of:

     ```
     a function                 → a handler
     script objects             → script objects inside this one
     named with the code 'pare' → property parent : …
     named with another code    → a property named with a keyword
     anything else              → a property
     ```

     `parentScopes` holds the names of the tables around this one, the
     nearest first. A handler reaches them with `PushParentVariable`.

     A problem in a handler is recorded as a diagnostic and the handler
     is left out.
     */
    func scriptObject(_ table: ScriptTable, _ parentScopes: [NameScope]) -> ScriptObject {
        let object = ScriptObject(name: table.name.identifier(or: unnamedScriptObject))
        let scope = NameScope(table.names.enumerated().map { $0.element.identifier(or: "var_\($0.offset)") })
        let scopes = [scope] + parentScopes
        defer {
            if let line = self.globalsLine(for: object.members, of: table, names: scope.names) {
                object.members.insert(line, at: 0)
            }
        }
        for child in table.parentObjects {
            object.members.append(.object(self.scriptObject(child, scopes)))
        }
        for entry in table.entries {
            switch entry.kind {
            case .value:
                if let property = self.property(entry, of: table) {
                    object.members.append(.property(property))
                }
            case let .scriptObjects(tables):
                for child in tables {
                    object.members.append(.object(self.scriptObject(child, scopes)))
                }
            case let .function(function):
                do {
                    let handler = try self.function(function, scopes)
                    self.nameAfterEntry(handler, entry, function)
                    object.members.append(.handler(handler))
                } catch {
                    self.report(function.offset, "\(table.path): \(error.message)")
                }
            }
        }
        return object
    }

    /**
     Gives a handler the name of its entry, when that is not the name
     the handler has for itself.

     The compiler stores the same name twice, in the table and in the
     handler. A call finds a handler by the name of the table. A file in
     which the two names differ was changed after it was compiled, so
     the handler is printed under the name that calls use, and the other
     name is reported.
     */
    func nameAfterEntry(_ handler: Handler, _ entry: Entry, _ function: Function) {
        guard
            let stored = entry.name?.bytes,
            let own = function.name.bytes,
            stored != own
        else {
            return
        }
        let name = String(decoding: stored, as: UTF8.self)
        self.report(function.offset, "the handler stored as \(name.quoted) names itself \(String(decoding: own, as: UTF8.self).quoted)")
        if name.isName {
            handler.name = name
        }
    }

    /**
     Returns the `global` line that a script, or a script object, has
     outside its handlers, or `nil` when it needs none.

     ```
     global g                      script s
                                       on f() … end f
     script s                      end script
         on f() … end f
     end script                    on helper()
                                       global g
     on helper()                       return g
         return g                  end helper
     end helper
     ```

     `helper` reads `g` with the same instruction in both scripts. What
     differs is the table of `s`: on the left it keeps a link to the
     table around it. The compiler makes that link when a name of the
     script around is used somewhere: a property, a script object, or a
     name declared `global` there. The compiler was asked with some
     twenty small scripts.

     A property or a script object is read with its own instruction
     (`PushParentVariable`), so that use is seen. When a script object
     has the link and no such use explains it, a `global` line does.

     The names of the line are globals used inside the script objects,
     or else at this level. A name that a handler of a script object
     uses as its own variable is left out: the line would turn it into
     the global.

     - `members`: what was read at this level.
     - `table`: the stored table of this level.
     - `names`: the names of the table: properties, handlers and script
       objects, which are never globals.
     */
    func globalsLine(for members: [Member], of table: ScriptTable, names: [String]) -> Member? {
        guard
            table.scriptObjects.contains(where: { $0.raw.children.first?.vector != nil }),
            !self.usesTable(members, distance: 1)
        else {
            return nil
        }
        let inside = members.compactMap(\.object).flatMap(\.members)
        var excluded = Set(names).union(self.handlers(in: inside).flatMap { self.handlerUse[ObjectIdentifier($0)]?.locals ?? [] })
        func globals(_ members: [Member]) -> [String] {
            self.handlers(in: members).flatMap { self.handlerUse[ObjectIdentifier($0)]?.globals ?? [] }.filter { excluded.insert($0).inserted }
        }
        var found = globals(inside)
        if found.isEmpty {
            found = globals(members)
        }
        return found.isEmpty ? nil : .globals(Declaration(names: found, global: true))
    }

    /** The handlers of some members, and of the script objects in them, at any depth. */
    func handlers(in members: [Member]) -> [Handler] {
        members.flatMap { member -> [Handler] in
            switch member {
            case let .handler(handler): [handler]
            case let .object(object): self.handlers(in: object.members)
            default: []
            }
        }
    }

    /**
     True when a handler reads or sets a name of the table that is
     `distance` tables up from it: 1 for the handlers of `members`, 2
     for the handlers of the script objects in them, and so on.
     */
    func usesTable(_ members: [Member], distance: Int) -> Bool {
        members.contains { member in
            switch member {
            case let .handler(handler): (self.handlerUse[ObjectIdentifier(handler)]?.parentDepth ?? 0) >= distance
            case let .object(object): self.usesTable(object.members, distance: distance + 1)
            default: false
            }
        }
    }

    /**
     Returns the property that an entry of a table is, or `nil` when it
     is none. The name of the entry tells what it is:

     - the code `pare`: `property parent : …`;
     - any other code: a property named with a word of the language or
       of an application, such as `property size : 3`;
     - a plain identifier: a property with that name.
     */
    func property(_ entry: Entry, of table: ScriptTable) -> Property? {
        guard let nameValue = entry.name else {
            return nil
        }
        if nameValue.isConstant("pare") {
            let parent = Keyword(code: .four("pare"), fallback: "parent")
            return self.parentInitializer(table.parent, in: entry.offset).map { Property(keyword: parent, value: $0) }
        }
        self.literalPath.owner = table
        defer { self.literalPath.owner = nil }
        let value = self.rootInitializer(entry.value, in: entry.offset)
        if let keyword = nameValue.propertyKeyword {
            return Property(keyword: keyword, value: value)
        }
        let name = nameValue.identifier(or: "")
        if name.isEmpty {
            return nil
        }
        return Property(name: name, value: value)
    }

    /**
     Returns the value of `property parent`, or `nil` when the script
     object has none.

     When the parent is another script object, the stored value is the
     wrapper of that object, and its name is printed:
     `property parent : base`. Any other value is printed like the
     initial value of a property, for example `application "Finder"`.
     */
    func parentInitializer(_ parent: Value?, in slot: Int) -> (any Expr)? {
        guard let parent else {
            return nil
        }
        if let wrapper = parent.vector, wrapper.hasType, wrapper.type == 15, wrapper.children.count > 1 {
            return Variable(name: wrapper.children[1].identifier(or: unnamedScriptObject))
        }
        return self.rootInitializer(parent, in: slot)
    }

    /**
     Returns the initial value of a property.

     One wrapped form is recognised here (runtime class 20 around a
     descriptor vector):

     ```
     class 24   script "<library name>"      (when its kind is 'scpt')
                class "<Objective-C class>"  (when its kind is 'pcls')
     ```

     Anything else is a plain literal: `a reference to <property> of
     <target>` (class 20 around a stored reference) is one, see
     `LiteralPath`.
     */
    func rootInitializer(_ entry: Value, in slot: Int) -> any Expr {
        // `property h : helper`, `property s : inner`: the value is a
        // handler or a script object, which has a name of its own.
        if entry.isTypedFunctionVector, let function = entry.vector.flatMap({ Function(offset: slot, vector: $0) }) {
            let name = function.name.identifier(or: "")
            if !name.isEmpty {
                return Variable(name: name)
            }
        }
        if let wrapper = entry.vector, wrapper.hasType, wrapper.type == 15, wrapper.children.count == 5, wrapper.children[4].vector != nil {
            return Variable(name: wrapper.children[1].identifier(or: unnamedScriptObject))
        }
        guard
            let outer = entry.vector,
            outer.type == 20,
            outer.children.count > 1,
            let descriptor = outer.children[1].vector
        else {
            return self.literal(entry, in: slot)
        }
        if descriptor.type == 24, descriptor.children.count > 3, descriptor.children[2].isConstant("scpt"), let name = self.literal(descriptor.children[3], in: slot) as? StringLiteral {
            return ScriptLibrary(name: name.value)
        }
        // `class "NSObject"`: an Objective-C class, by its name.
        if descriptor.type == 24, descriptor.children.count > 3, descriptor.children[2].isConstant("pcls"), let name = self.literal(descriptor.children[3], in: slot) as? StringLiteral {
            return Specifier(kind: .index, object: Keyword(code: .four("pcls"), fallback: "class"), from: name)
        }
        return self.literal(entry, in: slot)
    }

    /**
     Reads the `use` lines kept in the list of imports: the version of
     AppleScript, scripting additions, frameworks and applications. (A
     script library is an entry of the table: see `rootValue`.)
     */
    func extractUses(_ entry: Entry) {
        guard
            let outer = entry.value.vector,
            outer.children.count > 2,
            let list = outer.children[2].vector
        else {
            return
        }
        let start = list.hasType ? 1 : 0
        for child in list.children.dropFirst(start) {
            guard let binding = child.binding else {
                continue
            }
            if binding.key.isConstant("vers") {
                if let version = self.literal(binding.value, in: entry.offset) as? StringLiteral {
                    self.output.members.append(.use(Use(name: version.value, version: true)))
                }
                continue
            }
            if case .descriptor = binding.value {
                if let application = self.literal(binding.value, in: entry.offset) as? Application {
                    self.output.members.append(.use(Use(name: application.name, application: true)))
                }
                continue
            }
            guard
                let wrapper = binding.value.vector,
                wrapper.children.count > 1,
                let descriptor = wrapper.children[1].vector
            else {
                continue
            }
            if descriptor.type == 25, descriptor.children.count > 4, descriptor.children[2].isConstant("capp") {
                // `use application id "com.apple.finder"`: the class, the text, and the key form.
                if let name = self.literal(descriptor.children[3], in: entry.offset) as? StringLiteral {
                    let isIdentifier = descriptor.children[4].isConstant("ID  ")
                    self.output.members.append(.use(Use(name: name.value, application: true, isIdentifier: isIdentifier)))
                }
            } else if descriptor.type == 24, descriptor.children.count > 3, descriptor.children[2].isConstant("frmk") {
                if let name = self.literal(descriptor.children[3], in: entry.offset) as? StringLiteral {
                    self.output.members.append(.use(Use(name: name.value, framework: true)))
                }
            } else if descriptor.type == 22, descriptor.children.count > 2, descriptor.children[2].isConstant("osax") {
                self.output.members.append(.use(Use(scriptingAdditions: true)))
                self.usesScriptingAdditions = true
            }
        }
    }

    /**
     Rebuilds one handler from its function.

     - `isTopLevel`: the function is in the table of the script itself,
       not in a script object. It matters for the run handler: see
       `declarations`.
     - Throws: in strict mode, on the first problem.
     */
    func function(_ function: Function, _ parentScopes: [NameScope], isTopLevel: Bool = false) throws -> Handler {
        let decoded = try decode(function.offset, function.code, strict: self.options.strict, limit: self.instructionBudget)
        self.instructionBudget -= decoded.instructions.count
        if decoded.isCut {
            let message = "the script has more than \(maximumInstructions) instructions: the rest of its code is not read"
            if self.options.strict {
                throw ScriptError(message)
            }
            // Once for the handler that is cut, not for each one after it.
            if !self.reportedInstructionLimit {
                self.reportedInstructionLimit = true
                self.report(function.offset, message)
            }
        }
        // A decoding problem met here is reported by this stage.
        for var item in decoded.diagnostics {
            item.stage = .decompile
            self.add(item)
        }
        let stored = StoredParameters(function)
        let parameterCount = stored.nameCount
        var variables: [String] = []
        for (index, value) in function.variables.enumerated() {
            let fallback = index < parameterCount ? "arg_\(index)" : "var_\(index)"
            variables.append(value.identifier(or: fallback))
        }
        let (name, event, isRun) = function.name.functionName(self.options.terms)
        let handler = Handler(name: name, eventCode: event, isRunHandler: isRun)
        if case let .object(.eventIdentifier(identifier)) = function.name {
            handler.isRawEvent = identifier.isRawForm
        }
        handler.parameters = stored.parameters(isUserHandler: event == nil, variables: variables)
        let state = State(decompiler: self, function: function, handler: handler, variables: variables, parentScopes: parentScopes)
        for inst in decoded.instructions {
            state.closeAt(inst.offset)
            state.closeLogic(inst.offset)
            do {
                try state.instruction(inst)
            } catch {
                self.report(function.offset, at: inst.offset, error.message)
                if self.options.strict {
                    throw error
                }
            }
            if state.underflow {
                let error = ScriptError("expression stack underflow")
                self.report(function.offset, at: inst.offset, error.message)
                state.underflow = false
                if self.options.strict {
                    throw error
                }
            }
            state.previous = inst.opcode
        }
        state.closeAt(1 << 30)
        while state.blocks.count > 1 {
            state.closeTop()
        }
        if state.pending != nil, !state.stack.isEmpty {
            state.assignPending(state.read(state.pop()))
        }
        state.flushPatternParts()
        handler.body = self.nestUsingTerms(handler.body)
        self.handlerUse[ObjectIdentifier(handler)] = (state.globalNames, variables, state.parentDepth)
        handler.body.insert(contentsOf: self.declarations(of: handler, state, isTopLevelRun: isTopLevel && isRun), at: 0)
        return handler
    }

    /**
     Puts in each `using terms from` block the statements that follow
     it. The compiled script says where a block starts, not where it
     ends (see `State.discard`), and the block only tells the compiler
     which words to read: so it is given all that is left of the block
     around it.

     ```
     using terms from application "Finder"      using terms from application "Finder"
     set a to 1                                     set a to 1
     set b to 2                                     set b to 2
                                                end using terms from
     ```
     */
    func nestUsingTerms(_ statements: [any Stmt]) -> [any Stmt] {
        // From the last statement to the first: `after` is what follows, last first.
        var after: [any Stmt] = []
        for statement in statements.reversed() {
            switch statement {
            case let node as If:
                node.then = self.nestUsingTerms(node.then)
                node.else = self.nestUsingTerms(node.else)
            case let node as Repeat:
                node.body = self.nestUsingTerms(node.body)
            case let node as Try:
                node.body = self.nestUsingTerms(node.body)
                node.errorBody = self.nestUsingTerms(node.errorBody)
            case let node as Tell:
                node.body = self.nestUsingTerms(node.body)
            case let node as Considering:
                node.body = self.nestUsingTerms(node.body)
            case let node as Timeout:
                node.body = self.nestUsingTerms(node.body)
            case let node as Transaction:
                node.body = self.nestUsingTerms(node.body)
            default:
                break
            }
            if let block = statement as? UsingTerms {
                block.body = after.reversed()
                after = [block]
            } else {
                after.append(statement)
            }
        }
        return after.reversed()
    }

    /**
     Returns the `global` and `local` lines a handler needs.

     The source says where a name lives, and the compiler picks the
     instruction from that:

     ```
     in a handler                         in the run handler of the script
     x          local   (PushVariable)    x          global  (PushGlobal)
     global x   global  (PushGlobal)      local x    local   (PushVariable)
     ```

     So a name read with the other instruction was declared. Without
     the line, the source would compile to different code.

     In a handler, a local with the name of a property of the script, or
     of a variable of a handler around it, was declared too: without
     `local x`, the name is the property.

     A parameter, the variable of a `repeat` and the variables of
     `on error` are local everywhere, with no line. So is the name of a
     script object made by a statement, `script s` … `end script`: with
     a `local s` line the compiler refuses the script.
     */
    func declarations(of handler: Handler, _ state: State, isTopLevelRun: Bool) -> [any Stmt] {
        var bound = Set(handler.parameters.flatMap(\.names))
        func collect(_ statements: [any Stmt]) {
            for statement in statements {
                if let node = statement as? Repeat {
                    bound.insert(node.variable)
                }
                if let node = statement as? Try {
                    bound.formUnion(node.names)
                }
                if let object = (statement as? Expression)?.value as? ScriptObject {
                    bound.insert(object.name)
                }
                statement.bodies.forEach(collect)
            }
        }
        collect(handler.body)
        if isTopLevelRun {
            let locals = state.localNames.filter { !bound.contains($0) }
            return locals.isEmpty ? [] : [Declaration(names: locals, global: false)]
        }
        let locals = state.localNames.filter { name in
            !bound.contains(name) && state.parentScopes.contains { $0.contains(name) }
        }
        return (locals.isEmpty ? [] : [Declaration(names: locals, global: false)])
            + (state.globalNames.isEmpty ? [] : [Declaration(names: state.globalNames, global: true)])
    }

    /**
     Rebuilds a script object defined inside a handler (`DefineActor`).

     `raw` is the initializer of the object, a function that answers the
     event `ascr` `init`:

     ```
     its variables    the properties of the object, by name or by code
     its code         gives each property its value, and the parent
     its literals     the handlers of the object
     ```

     A problem in one of them is recorded as a diagnostic.

     The initializer is a value of the file like any other, so a
     damaged file can make it hold itself, or hold the same one many
     times at each level:

     ```
     initializer ── literal ──▶ the same initializer
     ```

     One that is being rebuilt already is not entered again, and no
     more than `maximumScriptObjectsInHandlers` are rebuilt for one
     script. The object is then printed empty, with a diagnostic.
     */
    func actor(_ raw: Vector, _ name: String?, _ parentScopes: [NameScope]) -> ScriptObject {
        // Without a name from the handler, the name of the initializer is used.
        // A script object can have no name at all: `script … end script`.
        guard let initializer = Function(offset: 2, vector: raw) else {
            return ScriptObject(name: name ?? "")
        }
        let object = ScriptObject(name: name ?? initializer.name.identifier(or: ""))
        guard self.actorsBeingRebuilt.insert(ObjectIdentifier(raw)).inserted else {
            self.report(initializer.offset, "a script object is defined inside itself: it is printed empty")
            return object
        }
        defer { self.actorsBeingRebuilt.remove(ObjectIdentifier(raw)) }
        guard
            self.actorBudget > 0,
            self.actorsBeingRebuilt.count <= maximumScriptObjectDepth
        else {
            if !self.reportedActorLimit {
                self.reportedActorLimit = true
                self.report(
                    initializer.offset,
                    "more than \(maximumScriptObjectsInHandlers) script objects are defined in handlers, or more than "
                        + "\(maximumScriptObjectDepth) inside one another: the others are printed empty",
                )
            }
            return object
        }
        self.actorBudget -= 1
        let names = initializer.variables.enumerated().map { $0.element.identifier(or: "var_\($0.offset)") }
        do {
            let handler = try function(initializer, parentScopes)
            self.addMembers(handler.body, to: object, of: initializer, names: names)
        } catch {
            self.report(initializer.offset, error.message)
        }
        let scopes = [NameScope(names)] + parentScopes
        var offset = 3
        for value in initializer.literals {
            guard
                let procedureRaw = value.vector,
                let procedure = Function(offset: offset, vector: procedureRaw)
            else {
                continue
            }
            // The function that makes a script object defined inside this
            // one answers the event `ascr` `init`. That object is read
            // where it is defined, not as a handler.
            if procedure.name.eventCode == "ascrinit" {
                continue
            }
            do {
                try object.members.append(.handler(self.function(procedure, scopes)))
            } catch {
                self.report(offset, error.message)
            }
            offset += 1
        }
        return object
    }

    /**
     Reads the statements of the initializer of a script object into
     its properties and its script objects:

     ```
     script inner … end script     a script object defined inside this one
     set parent to x               property parent : x     (see `State.defineProperty`)
     set q to 2                    property q : 2
     set name to "n"               property name : "n"     (the variable is named by a code)
     ```

     `names` holds the names of the variables of the initializer, as
     the statements use them.
     */
    private func addMembers(_ statements: [any Stmt], to object: ScriptObject, of initializer: Function, names: [String]) {
        // A property named with a word of the language, like `size`, is a
        // variable whose name is stored as a code.
        var keywords: [String: Keyword] = [:]
        for (name, value) in zip(names, initializer.variables) {
            keywords[name] = value.propertyKeyword
        }
        for statement in statements {
            if let nested = (statement as? Expression)?.value as? ScriptObject {
                object.members.append(.object(nested))
                continue
            }
            guard let set = statement as? SetStmt else {
                continue
            }
            if let keyword = set.target as? Keyword {
                object.members.append(.property(Property(keyword: keyword, value: set.value)))
                continue
            }
            guard let variable = set.target as? Variable else {
                continue
            }
            if let keyword = keywords[variable.name] {
                object.members.append(.property(Property(keyword: keyword, value: set.value)))
                continue
            }
            object.members.append(.property(Property(name: variable.name, value: set.value)))
        }
    }
}

/**
 How many script objects defined inside handlers are rebuilt for one
 script, and how deep one can be inside the others. A real script has a
 few of them.
 */
let maximumScriptObjectsInHandlers = 4096

/**
 How many instructions are read in one script, all its handlers
 together. The 78 real scripts used for the tests have 27,000 of them
 together, and the longest handler is 754 bytes.

 What is made from an instruction takes about 300 times its size: 4 MB
 of made-up code took more than 1 GB. With this limit a file of any
 size takes a few hundred megabytes at most.
 */
let maximumInstructions = 1_000_000

/**
 How many bytes of text the statements of one script print again,
 before a long text that was printed before is replaced by a mark. One
 megabyte of text used by 3,000 statements, 12 KB of code, printed
 2.9 GB.
 */
let maximumRepeatedText = 1 << 26

/**
 How many nodes a part of a statement can print again once the handler
 is too large to print: see `State.emit`.
 */
let maximumRepeatedPart = 64

/** What is printed in place of a large part that was printed before: see `State.emit`. */
let printedAboveMark = "«value printed above»"

/** How many diagnostics one script keeps, and how many with the same message: see `Decompiler.add`. */
let maximumDiagnostics = 10000
let maximumRepeatedDiagnostics = 100
let maximumScriptObjectDepth = 16

/** The name printed for a script object whose name cannot be found. */
let unnamedScriptObject = "scriptObject"
