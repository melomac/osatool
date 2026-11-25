import AST
import Extensions

/**
 An assignment to a pattern: a list or a record of names.

 ```
 set {a, {b, c}} to value
 set {name:n, id:i} to value
 copy value to {a, b}
 ```

 The compiler has no instruction for a pattern. It keeps the value on
 the stack and stores one part of it into each name, one after the
 other:

 ```
 value                         the value, kept until the end
 Dup, item 1, PopVariable a, Pop        a = item 1 of the value
 Dup, item 2                            item 2, kept for its own parts
   Dup, item 1, PopVariable b, Pop      b = item 1 of item 2
   Dup, item 2, PopVariable c, Pop      c = item 2 of item 2
 Pop
 StoreResult                   the end of the statement
 ```

 `copy` has one more instruction, `Clone`, before each store.

 Each store is kept as a `PatternPart` (see `takePatternPart`). The
 statement is made when the value is stored as the result (see
 `patternAssignment`).
 */
struct PatternPart {
    /** The name that is set. */
    var target: any Expr
    /** The way from the value to the part: `[2, 1]` is item 1 of item 2. */
    var path: [PatternStep]
    /** The part as an expression: `item 1 of item 2 of value`. */
    var accessor: any Expr
    /** True when the part is copied (`copy`), false when it is set. */
    var isCopy: Bool
}

/** One step from a value to a part of it. */
enum PatternStep {
    /** Item `n` of a list, from 1. */
    case item(Int)
    /** The property with this label: a keyword, or a variable for a word of the user. */
    case property(any Expr)
}

/** A pattern while it is built: a name, a list of patterns, or a record of them. */
private final class PatternTree {
    var name: any Expr?
    var items: [PatternTree] = []
    var fields: [(label: any Expr, tree: PatternTree)] = []

    var isEmpty: Bool {
        self.name == nil && self.items.isEmpty && self.fields.isEmpty
    }

    /**
     Returns the tree at one step from this one, and makes it when it
     is new. The parts of a pattern come in order, so a step goes to the
     last child or to a new one after it.

     - Returns: `nil` when the step does not fit: the instructions are
       not the ones of a pattern.
     */
    func child(_ step: PatternStep) -> PatternTree? {
        if self.name != nil {
            return nil
        }
        switch step {
        case let .item(number):
            guard self.fields.isEmpty else {
                return nil
            }
            if number == self.items.count, let last = self.items.last {
                return last
            }
            guard number == self.items.count + 1 else {
                return nil
            }
            self.items.append(PatternTree())
            return self.items.last
        case let .property(label):
            guard self.items.isEmpty else {
                return nil
            }
            if let last = self.fields.last, last.label.isSameLabel(as: label) {
                return last.tree
            }
            self.fields.append((label, PatternTree()))
            return self.fields.last?.tree
        }
    }

    /** The pattern as an expression, or `nil` when a part of it has no name. */
    var expression: any Expr? {
        if let name {
            return name
        }
        if !self.items.isEmpty {
            let elements = self.items.map(\.expression)
            return elements.contains { $0 == nil } ? nil : List(elements: elements)
        }
        if !self.fields.isEmpty {
            var fields: [RecordField] = []
            for field in self.fields {
                guard let value = field.tree.expression else {
                    return nil
                }
                // A word of the user is a text label in a record.
                let label: any Expr = (field.label as? Variable).map { StringLiteral(value: $0.name) } ?? field.label
                fields.append(RecordField(label: label, value: value))
            }
            return Record(fields: fields)
        }
        return nil
    }
}

private extension Expr {
    /** True when two labels of a record are the same keyword or the same word. */
    func isSameLabel(as other: any Expr) -> Bool {
        if let left = self as? Keyword, let right = other as? Keyword {
            return left.code == right.code && left.fallback == right.fallback
        }
        if let left = self as? Variable, let right = other as? Variable {
            return left.name == right.name
        }
        return false
    }
}

extension State {
    /**
     Called for a `Pop` that comes after a store. When the top of the
     stack is a part of a value below it, the store is one part of a
     pattern: it is kept, and the top is removed.

     The part must hang from the stack, step by step:

     ```
     stack:  value | item 2 of value | item 1 of item 2 of value
                                       └ top: path [2, 1] from `value`
     ```

     - Returns: `false` when the top is not such a part. Nothing changes.
     */
    func takePatternPart(_ target: any Expr) -> Bool {
        guard self.stack.count >= 2 else {
            return false
        }
        // Each part is read before it is stored: that `get` is not from the source.
        var top = self.read(self.stack[self.stack.count - 1])
        var isCopy = false
        if let copy = top as? CopyExpr, let inner = copy.value {
            top = self.read(inner)
            isCopy = true
        }
        var path: [PatternStep] = []
        var node = top
        var index = self.stack.count - 2
        // A part kept for its own parts was read too: `get item 2 of value`.
        while index >= 0, let specifier = self.read(node) as? Specifier, let container = specifier.container,
              container === self.stack[index], let step = specifier.patternStep
        {
            path.insert(step, at: 0)
            node = container
            index -= 1
        }
        guard !path.isEmpty else {
            return false
        }
        // A part of another value: the parts kept so far are not a pattern.
        if let base = self.patternBase, base !== node {
            self.flushPatternParts()
        }
        self.patternBase = node
        self.patternParts.append(PatternPart(target: target, path: path, accessor: top, isCopy: isCopy))
        _ = self.pop()
        return true
    }

    /**
     Makes the statement for the parts kept by `takePatternPart`, when
     `value` is the value they all come from.

     - Returns: `nil` when there is no part, or when the parts do not
       make a pattern. The parts are then written one by one.
     */
    func patternAssignment(of value: any Expr) -> (any Stmt)? {
        guard !self.patternParts.isEmpty else {
            return nil
        }
        guard
            self.patternBase === value,
            let pattern = self.pattern(from: self.patternParts)
        else {
            self.flushPatternParts()
            return nil
        }
        let isCopy = self.patternParts[0].isCopy
        self.patternParts = []
        self.patternBase = nil
        let source = self.read(value)
        return isCopy ? Copy(source: source, target: pattern) : SetStmt(target: pattern, value: source)
    }

    /**
     Ends a statement whose value is still on the stack: when the top
     is the value of the parts kept so far, it is removed and the
     assignment to the pattern is emitted.

     - Returns: `false` when there is no such assignment to make.
     */
    func emitPatternAssignment() -> Bool {
        guard
            self.pending == nil,
            let top = self.stack.last,
            let assignment = self.patternAssignment(of: top)
        else {
            return false
        }
        _ = self.pop()
        self.emit(assignment)
        return true
    }

    /**
     Builds the pattern from its parts.

     - Returns: `nil` when the parts do not fit in one pattern, or when
       some are copied and others are set.
     */
    private func pattern(from parts: [PatternPart]) -> (any Expr)? {
        guard parts.allSatisfy({ $0.isCopy == parts[0].isCopy }) else {
            return nil
        }
        let root = PatternTree()
        for part in parts {
            var tree = root
            for step in part.path {
                guard let next = tree.child(step) else {
                    return nil
                }
                tree = next
            }
            guard tree.isEmpty else {
                return nil
            }
            tree.name = part.target
        }
        return root.expression
    }

    /**
     Writes the parts kept so far as one statement each, and forgets
     them: `set a to item 1 of value`. This is what is left to do when
     the instructions are not the ones of a pattern.

     Each statement prints the value again, so they are counted like
     any other statement (see `emit`). They were not: 40,000 parts of
     one value of 2,000 operands, 277 KB of code, printed 313 MB.
     */
    func flushPatternParts() {
        let parts = self.patternParts
        // Emptied first: `emit` writes the parts that are waiting.
        self.patternParts = []
        self.patternBase = nil
        for part in parts {
            self.emit(part.isCopy ? Copy(source: part.accessor, target: part.target) : SetStmt(target: part.target, value: part.accessor))
        }
    }
}

private extension Specifier {
    /**
     The step of one part: `item 3 of x` or `name of x`. Any other
     specifier gives `nil`.
     */
    var patternStep: PatternStep? {
        switch self.kind {
        case .index:
            guard
                (self.object as? Keyword)?.code == .four("cobj"),
                let number = self.from as? NumberLiteral,
                !number.isReal,
                number.integer >= 1,
                number.integer <= Int64(Int32.max)
            else {
                return nil
            }
            return .item(Int(number.integer))
        case .property:
            guard
                let label = self.object,
                label is Keyword || label is Variable
            else {
                return nil
            }
            return .property(label)
        default:
            return nil
        }
    }
}
