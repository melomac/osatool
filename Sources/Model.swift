import Extensions
import FAS

/**
 A compiled script, seen as tables of functions.

 The root of the file is a wrapper vector. Its last child is the table
 of the script. A script object has the same wrapper and the same table,
 so both are a `ScriptTable`:

 ```
 wrapper (class 15)
 ├─ [1]  name of the script object (nothing for the root)
 ├─ [3]  the parent: the value of `property parent`, or the default
 └─ [4]  the table
         ├─ [0]  the table around this one (nothing for the root)
         ├─ [1]  name table ──── name of entry 2, name of entry 3, …
         ├─ [2]  entry: a property value, a function, a script object
         ├─ [3]  entry
         └─ …
 ```

 So entry `n` has its name at index `n - 2` of the name table.

 Without `property parent`, the parent slot holds the default. For the
 root it is a marker. For a script object, at any depth, it is the root
 wrapper itself: the file stores a reference to 0, the number of the
 root object.

 ```
 root wrapper ◀──────────────┐
 └─ table                    │ [3]
    └─ wrapper of "main" ────┤
       └─ table              │ [3]
          └─ wrapper of "inner"
 ```
 */
package final class CompiledScript {
    package var document: Document
    /** The wrapper around the table of the script. */
    package var top: Vector
    /** The table of the script itself. */
    package var table: ScriptTable

    package init(document: Document = Document(), top: Vector = Vector(), table: ScriptTable = ScriptTable()) {
        self.document = document
        self.top = top
        self.table = table
    }

    /**
     Every script object, at any depth. A script object comes before the
     ones defined inside it.
     */
    package var allScriptObjects: [ScriptTable] {
        func flat(_ tables: [ScriptTable]) -> [ScriptTable] {
            tables.flatMap { [$0] + flat($0.scriptObjects) }
        }
        return flat(self.table.scriptObjects)
    }
}

/** What an entry of a script table holds. */
package enum EntryKind {
    /** A handler. */
    case function(Function)
    /**
     One script object, or several when the value is a list of them.
     The table of a script object can be deep inside the value.
     */
    case scriptObjects([ScriptTable])
    /** Anything else: the value of a property, or data of the runtime. */
    case value

    package var isValue: Bool {
        if case .value = self {
            true
        } else {
            false
        }
    }
}

/** One entry of a script table. */
package struct Entry {
    /** The index of the entry in the table: 2 for the first one. */
    package var offset: Int
    /** The name of the entry, or `nil` when the name table is too short. */
    package var name: Value?
    package var value: Value
    package var kind: EntryKind

    package init(offset: Int, name: Value?, value: Value, kind: EntryKind = .value) {
        self.offset = offset
        self.name = name
        self.value = value
        self.kind = kind
    }
}

/**
 The table of the script, or of a script object. (AppleScript calls a
 script object an "actor".)
 */
package final class ScriptTable {
    /** The table as it is stored. */
    package var raw: Vector
    /** Where the table was found, for example `root[3].vector[4]`. */
    package var path: String
    /** The index of the entry, in the table around this one, that holds it. */
    package var entryOffset: Int
    /** The name of the script object, or `nil` when it has none. */
    package var name: Value?
    /** The value of `property parent`, or `nil` when the source has none. */
    package var parent: Value?
    /**
     The script objects found in the value of `property parent`, when
     no entry of the file defines them: a script that was loaded when
     the source was compiled (see `ScriptObjectFinder.searchParents`).
     */
    package var parentObjects: [ScriptTable] = []
    /** The name table: one name for each entry, in order. */
    package var names: [Value]
    package var entries: [Entry]

    package init(
        raw: Vector = Vector(), path: String = "root", entryOffset: Int = 0, name: Value? = nil,
        names: [Value] = [], entries: [Entry] = [],
    ) {
        self.raw = raw
        self.path = path
        self.entryOffset = entryOffset
        self.name = name
        self.names = names
        self.entries = entries
    }

    /** The handlers of the table, in the order of the entries. */
    package var functions: [Function] {
        self.entries.compactMap { entry -> Function? in
            if case let .function(function) = entry.kind {
                function
            } else {
                nil
            }
        }
    }

    /**
     The script objects of the table: those of its parent that are
     defined nowhere else, then those of its entries, in order.
     */
    package var scriptObjects: [ScriptTable] {
        self.parentObjects + self.entries.flatMap { entry -> [ScriptTable] in
            if case let .scriptObjects(tables) = entry.kind {
                tables
            } else {
                []
            }
        }
    }
}

/**
 One handler, taken from a function vector. The vector has eight children:

 ```
 [1] name                 [5] variable names
 [3] arguments            [6] literals
 [4] labeled arguments    [7] bytecode
 ```

 `arguments` is a pattern: a name (`on run argv`), or a list of names
 and patterns (`on mix(a, b)`, `on run {a, b}`). It is empty when the
 handler has no direct parameter.

 `labels` is a chain of bindings, one for each labeled parameter. The
 key is the label and the value is the pattern that receives it:

 ```
 on describe to x given flag:f      'to  ' → x,  "flag" → f
 ```
 */
package final class Function {
    /** The index of the entry that holds the function, in its table. */
    package var offset: Int
    package var raw: Vector
    package var name: Value
    package var arguments: Value
    package var labels: Value
    package var variables: [Value]
    package var literals: [Value]
    package var code: [UInt8]

    package init(
        offset: Int, raw: Vector = Vector(), name: Value = .null, arguments: Value = .null,
        labels: Value = .null, variables: [Value] = [], literals: [Value] = [], code: [UInt8] = [],
    ) {
        self.offset = offset
        self.raw = raw
        self.name = name
        self.arguments = arguments
        self.labels = labels
        self.variables = variables
        self.literals = literals
        self.code = code
    }

    /** Returns literal `index`, or `nil` when the index is out of range. */
    package func literal(_ index: Int) -> Value? {
        self.literals.indices.contains(index) ? self.literals[index] : nil
    }
}

/**
 Finds the table of the script, its functions and its script objects.

 - Throws: `ScriptError` when the root does not have the expected shape.
 */
package func normalize(_ document: Document) throws -> CompiledScript {
    guard let top = document.root.vector else {
        throw ScriptError("compiled document root is \(document.root.typeName), want vector")
    }
    guard let last = top.children.last else {
        throw ScriptError("compiled document root is empty")
    }
    guard let raw = last.vector else {
        throw ScriptError("compiled script table is \(last.typeName), want vector")
    }
    let table = ScriptTable(raw: raw)
    var finder = ScriptObjectFinder(top: top, own: OwnNames(in: document.root))
    // Without the property, the slot holds a marker for the default parent.
    if top.hasType, top.type == 15, top.children.count == 5, !top.children[3].isNull, top.children[3] != .secondActor {
        table.parent = top.children[3]
        finder.withParent.append(table)
    }
    if raw.children.count > 1, let names = raw.children[1].vector {
        table.names = names.items
    }
    // A script object keeps a link to the table around it. The root is
    // marked as visited, so that such a link is not followed back to it.
    finder.seen.enter(raw)
    for offset in raw.children.indices.dropFirst(2) {
        let index = offset - 2
        var entry = Entry(offset: offset, name: index < table.names.count ? table.names[index] : nil, value: raw.children[offset])
        let isAlias = finder.own.isAlias(entry)
        // At the top level, a function vector does not have to be typed.
        if let vector = entry.value.vector, let function = Function(offset: offset, vector: vector), !isAlias {
            entry.kind = .function(function)
        } else if !isAlias {
            entry.kind = finder.scriptObjects(in: entry, of: table)
        }
        table.entries.append(entry)
    }
    finder.searchParents()
    return CompiledScript(document: document, top: top, table: table)
}

/**
 The handlers and the script objects that an entry of a table holds
 under their own name.

 A handler and a script object keep their name in their slot 1. The
 entry that defines one has the same name. Another entry can hold the
 same handler or script object under another name:

 ```
 on helper() … end helper        entry "helper" ──▶ the handler "helper"
 property h : helper             entry "h" ──────▶ the same handler
 ```

 `h` is an alias: the handler is printed once, at `helper`. But an
 entry with another name is an alias only when the definition is
 somewhere. A file can be made with a handler that no entry holds under
 its own name; taken for an alias, it would not be shown at all.

 The definition can be in another table than the alias, so the whole
 file is read once to find them.
 */
struct OwnNames {
    private var defined: Set<ObjectIdentifier> = []

    /** Creates an empty set: no entry is an alias. */
    init() {}

    /** Finds every definition in the graph under `root`. Each container is read once. */
    init(in root: Value) {
        var seen = Visited()
        var waiting = [root]
        while let value = waiting.popLast() {
            guard seen.enter(value) else {
                continue
            }
            if let table = value.vector, !table.hasType, table.children.count > 2, let names = table.children[1].vector?.items {
                for (name, entry) in zip(names, table.children.dropFirst(2)) {
                    if let own = name.bytes, let vector = entry.vector, vector.children.count > 1, vector.children[1].bytes == own {
                        self.defined.insert(ObjectIdentifier(vector))
                    }
                }
            }
            value.appendChildren(to: &waiting)
        }
    }

    /**
     True for an entry that holds a handler or a script object under
     another name than its own, when an entry holds it under its own.
     */
    func isAlias(_ entry: Entry) -> Bool {
        guard
            let name = entry.name?.bytes,
            let vector = entry.value.vector,
            vector.children.count > 1,
            let own = vector.children[1].bytes,
            name != own
        else {
            return false
        }
        return self.defined.contains(ObjectIdentifier(vector))
    }
}

/**
 Where a value is in the file: its place in the value it is inside of,
 and the place of that one. The text, like `root[3].vector[1].head`, is
 made only when it is asked for: a search goes through every value, and
 a text for each one would cost the square of the depth.
 */
final class Place {
    private var parent: Place?
    private let name: String

    init(_ name: String, in parent: Place? = nil) {
        self.name = name
        self.parent = parent
    }

    /** The place of item `index` of a vector or of a statement: `vector[3]`. */
    convenience init(_ name: String, _ index: Int, in parent: Place) {
        self.init("\(name)[\(index)]", in: parent)
    }

    var text: String {
        var names = [self.name]
        var next = self.parent
        while let place = next {
            names.append(place.name)
            next = place.parent
        }
        return names.reversed().joined(separator: ".")
    }

    // The place of the last cell of a long list has one place above it for
    // each cell. Freed one from inside the other, they would fill the stack.
    deinit {
        var next = self.parent
        self.parent = nil
        while next != nil, isKnownUniquelyReferenced(&next) {
            let above = next?.parent
            next?.parent = nil
            next = above
        }
    }
}

/**
 The search for the script objects of a file.

 The script objects defined inside one that is found are searched too,
 and kept in its entries: the result is a tree, like the source.
 */
struct ScriptObjectFinder {
    /** The root wrapper: a script object with no `property parent` has it as its parent. */
    let top: Vector
    /** Which entries are another name for a handler or a script object. */
    let own: OwnNames
    /** The containers already visited, so a shared one or a loop in the graph is walked only once. */
    var seen = Visited()
    /** The tables that have a `property parent`, in the order they were found: see `searchParents`. */
    var withParent: [ScriptTable] = []

    init(top: Vector, own: OwnNames = OwnNames()) {
        self.top = top
        self.own = own
    }

    /**
     Searches the value of an entry of a table for script objects.

     - Returns: `.scriptObjects` with what was found, or `.value`.
     */
    mutating func scriptObjects(in entry: Entry, of table: ScriptTable) -> EntryKind {
        let found = self.search(entry.value, at: Place("\(table.path)[\(entry.offset)]"), entryOffset: entry.offset, name: entry.name)
        return found.isEmpty ? .value : .scriptObjects(found)
    }

    /**
     Walks a value and collects the tables of the script objects in it.

     The values still to visit wait in a list, so that a long list or a
     deep value does not use the stack.

     - `start`: where the value is. Each step down adds the name of the
       place (see `Value.children`).
     - `entryOffset`, `name`: given to each table that is found.
     */
    mutating func search(_ value: Value, at start: Place, entryOffset: Int, name: Value?) -> [ScriptTable] {
        var found: [ScriptTable] = []
        var waiting: [(value: Value, place: Place)] = [(value, start)]
        while let (value, place) = waiting.popLast() {
            guard self.seen.enter(value) else {
                continue
            }
            if let vector = value.vector, let table = self.table(of: vector, at: place, entryOffset: entryOffset, name: name) {
                found.append(table)
                self.searchEntries(of: table)
                continue
            }
            // The last one added is the first one visited: the children are added from the last to the first.
            switch value {
            case let .object(inner):
                waiting.append((inner, Place("object", in: place)))
            case let .pair(pair):
                waiting.append((pair.tail, Place("tail", in: place)))
                waiting.append((pair.head, Place("head", in: place)))
            case let .binding(binding):
                waiting.append((binding.next, Place("next", in: place)))
                waiting.append((binding.extra, Place("extra", in: place)))
                waiting.append((binding.value, Place("value", in: place)))
                waiting.append((binding.key, Place("key", in: place)))
            case let .vector(vector):
                for index in vector.children.indices.reversed() where vector.children[index].hasChildren {
                    waiting.append((vector.children[index], Place("vector", index, in: place)))
                }
            case let .statement(statement):
                for index in statement.children.indices.reversed() where statement.children[index].hasChildren {
                    waiting.append((statement.children[index], Place("statement", index, in: place)))
                }
            default:
                break
            }
        }
        return found
    }

    /**
     Returns the table of a script object, when `vector` is one:

     - the wrapper of a script object. Its other children are its name
       and its parent: they are not searched here (see `searchParents`);
     - a table with no wrapper around it.
     */
    private mutating func table(of vector: Vector, at place: Place, entryOffset: Int, name: Value?) -> ScriptTable? {
        if vector.hasType, vector.type == 15, vector.children.count == 5, let raw = vector.children[4].vector, !self.seen.contains(raw),
           let table = raw.scriptTable(own: self.own, entryOffset: entryOffset, name: name, needsFunction: false)
        {
            self.seen.enter(raw)
            table.path = place.text + ".vector[4]"
            // The root wrapper is the default: the source has no property then.
            if !vector.children[3].isNull, vector.children[3].vector !== self.top {
                table.parent = vector.children[3]
                self.withParent.append(table)
            }
            return table
        }
        if let table = vector.scriptTable(own: self.own, entryOffset: entryOffset, name: name) {
            table.path = place.text
            return table
        }
        return nil
    }

    /** Searches the entries of a table that was found. */
    private mutating func searchEntries(of table: ScriptTable) {
        for index in table.entries.indices {
            if case .value = table.entries[index].kind, !self.own.isAlias(table.entries[index]) {
                table.entries[index].kind = self.scriptObjects(in: table.entries[index], of: table)
            }
        }
    }

    /**
     Searches the value of each `property parent`, once every entry was
     searched.

     The parent is most often a script object of the file, defined by an
     entry and found there. But the value of a property is made when the
     source is compiled, and it can be a whole script that is stored
     nowhere else:

     ```
     property parent : load script file "library.scpt"
     ```

     The handlers of that library are then in the file, in the parent
     slot only. They are kept in `parentObjects`, so that they are shown
     like any other script object. A parent that was found at a place of
     its own is not found again here.
     */
    mutating func searchParents() {
        var index = 0
        while index < self.withParent.count {
            let table = self.withParent[index]
            index += 1
            guard
                let parent = table.parent,
                let wrapper = parent.vector
            else {
                continue
            }
            let name = wrapper.children.count > 1 && wrapper.children[1].bytes != nil ? wrapper.children[1] : nil
            table.parentObjects = self.search(parent, at: Place("\(table.path).parent"), entryOffset: 0, name: name)
        }
    }
}

extension Vector {
    /**
     Checks whether the vector is the table of a script object, and builds it.

     A table is an untyped vector whose name table has exactly one name per
     entry. Without a wrapper around it (`needsFunction`), it must also hold
     at least one typed function vector, or any small vector would match.

     The entries of the result are functions or plain values: the script
     objects inside them are searched by the caller, which also gives the
     table its path.
     */
    func scriptTable(own: OwnNames = OwnNames(), entryOffset: Int, name: Value?, needsFunction: Bool = true) -> ScriptTable? {
        // A table always has the link to the table around it and its name
        // table. A script object with nothing in it has only those two.
        if self.hasType || self.children.count < (needsFunction ? 3 : 2) {
            return nil
        }
        // The count is compared before the names are taken: most vectors are not tables.
        guard
            let nameTable = self.children[1].vector,
            nameTable.itemCount == self.children.count - 2
        else {
            return nil
        }
        let names = nameTable.items
        let table = ScriptTable(raw: self, path: "", entryOffset: entryOffset, name: name, names: names)
        for offset in self.children.indices.dropFirst(2) {
            var entry = Entry(offset: offset, name: names[offset - 2], value: self.children[offset])
            // Inside a script object, only a typed vector is a function.
            if entry.value.isTypedFunctionVector, let vector = entry.value.vector, let function = Function(offset: offset, vector: vector),
               !own.isAlias(entry)
            {
                entry.kind = .function(function)
            }
            table.entries.append(entry)
        }
        if needsFunction, table.functions.isEmpty {
            return nil
        }
        return table
    }
}

package extension Value {
    /** True for a typed vector (class 16 or 17) of 8 children ending in bytecode. */
    var isTypedFunctionVector: Bool {
        guard
            let raw = self.vector,
            raw.hasType,
            raw.children.count == 8
        else {
            return false
        }
        if raw.type != 16, raw.type != 17 {
            return false
        }
        return raw.children[7].bytes != nil
    }
}

package extension Function {
    /**
     Builds a function from a function vector.

     - Returns: `nil` when the vector has fewer than 8 children or when
       child 7 is not a byte string.
     */
    convenience init?(offset: Int, vector raw: Vector) {
        guard
            raw.children.count >= 8,
            let code = raw.children[7].bytes
        else {
            return nil
        }
        self.init(offset: offset, raw: raw, name: raw.children[1], arguments: raw.children[3], labels: raw.children[4], code: code)
        if let variables = raw.children[5].vector {
            self.variables = variables.items
        }
        if let literals = raw.children[6].vector {
            self.literals = literals.items
        }
    }
}
