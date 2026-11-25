import FAS
import Model
import Testing

/** A byte string value that holds the UTF-8 bytes of `text`. */
func bytes(_ text: String) -> Value {
    .bytes(Array(text.utf8))
}

@Test func `function vector normalization`() throws {
    let name = bytes("handler")
    let arguments = bytes("argument")
    let variables = Value.vector(Vector(hasType: true, children: [.null, bytes("argument"), bytes("local")]))
    let literals = Value.vector(Vector(hasType: true, children: [.null, .integer(1), .integer(2)]))
    let raw = Vector(children: [
        .null, name, .null, arguments, .null, variables, literals, .bytes([0x6b, 0x0f]),
    ])
    let function = try #require(Function(offset: 7, vector: raw), "valid function vector rejected")
    #expect(function.offset == 7)
    #expect(function.name == name)
    #expect(function.arguments == arguments)
    #expect(function.variables == [bytes("argument"), bytes("local")])
    #expect(function.literals == [.integer(1), .integer(2)])
    #expect(function.code == [0x6b, 0x0f])

    // The function has its own copy of the bytecode.
    raw.children[7] = .bytes([0, 0])
    #expect(function.code.first == 0x6b)
}

@Test func `function literal index guard`() {
    let function = Function(offset: 0, literals: [.integer(1), .integer(2)])
    #expect(function.literal(1) == .integer(2))
    // `nil` means the index is out of range.
    for index in [-1, 2] {
        #expect(function.literal(index) == nil, "literal \(index) found")
    }
}

@Test func `normalize rejects invalid shapes`() {
    #expect(throws: (any Error).self, "scalar root accepted") {
        try normalize(Document(root: .integer(1)))
    }
    #expect(throws: (any Error).self, "empty root accepted") {
        try normalize(Document(root: .vector(Vector())))
    }
    #expect(throws: (any Error).self, "scalar script table accepted") {
        try normalize(Document(root: .vector(Vector(children: [.integer(1)]))))
    }
}

/**
 A script object can be stored deep inside another value. Here it is the
 content of an object, and it also points back to itself through a
 wrapper vector.
 */
@Test func `normalize discovers nested actor table`() throws {
    let handlerName = bytes("clicked_")
    let handler = Vector(
        type: 16, hasType: true,
        children: [
            .null, handlerName, .null, .null, .null,
            .vector(Vector()), .vector(Vector()), .bytes([0x0f]),
        ],
    )
    let actor = Vector()
    let wrapper = Vector(children: [.vector(actor)])
    actor.children = [
        .null,
        .vector(Vector(children: [bytes("object"), handlerName])),
        .vector(wrapper), .vector(handler),
    ]
    // Break the loop at the end, so the nodes can be freed.
    defer { wrapper.children = [] }
    let actorName = bytes("AppDelegate")
    let root = Vector(children: [
        .null,
        .vector(Vector(children: [actorName])),
        .object(.vector(actor)),
    ])
    let document = Document(root: .vector(Vector(children: [.vector(root)])))

    let script = try normalize(document)
    try #require(script.table.scriptObjects.count == 1)
    let got = script.table.scriptObjects[0]
    #expect(got.name == actorName)
    #expect(got.raw === actor)
    #expect(got.entryOffset == 2)
    #expect(got.path == "root[2].object")
    try #require(got.functions.count == 1)
    #expect(got.functions[0].name == handlerName)
    #expect(got.functions[0].offset == 3)
}

/**
 A vector with eight children and bytecode in the last one looks like a
 function. It is one only when it is typed, so no actor is found here.
 */
@Test func `actor discovery rejects untyped name vector false positive`() throws {
    let fake = Vector(children: [Value](repeating: .null, count: 8))
    fake.children[7] = .bytes([0x0f])
    let actor = Vector(children: [
        .null,
        .vector(Vector(children: [bytes("object"), bytes("notAHandler")])),
        .null, .vector(fake),
    ])
    let root = Vector(children: [
        .null,
        .vector(Vector(children: [bytes("candidate")])),
        .vector(actor),
    ])
    let script = try normalize(Document(root: .vector(Vector(children: [.vector(root)]))))
    #expect(script.table.scriptObjects.isEmpty, "false actor discovered")
}

// MARK: - Entries under another name, parents, and large values

/** A typed function vector named `name`, with one instruction. */
private func handlerVector(_ name: String) -> Vector {
    Vector(type: 16, hasType: true, children: [.null, bytes(name), .null, .null, .null, .null, .null, .bytes([0x0f])])
}

/** The wrapper of a script object: its name, its parent, its table. */
private func wrapperVector(_ name: Value, parent: Value, table: Vector) -> Vector {
    Vector(type: 15, hasType: true, children: [.null, name, .null, parent, .vector(table)])
}

/** A table: the link to the table around it, the names, then one entry for each name. */
private func tableVector(_ entries: [(name: Value, value: Value)]) -> Vector {
    Vector(children: [.null, .vector(Vector(children: entries.map(\.name)))] + entries.map(\.value))
}

/** The root wrapper around a table. */
private func document(_ table: Vector, parent: Value = .secondActor) -> Document {
    Document(root: .vector(wrapperVector(.null, parent: parent, table: table)))
}

/**
 `property h : helper` stores the handler `helper` again, under the name
 `h`: an alias, printed as a property. But a handler stored only under
 another name is not an alias of anything. A file can be made that way,
 and the handler must still be shown.
 */
@Test func `a handler stored only under another name is kept`() throws {
    let helper = handlerVector("helper")
    let alias = try normalize(document(tableVector([(bytes("helper"), .vector(helper)), (bytes("h"), .vector(helper))])))
    #expect(alias.table.functions.count == 1 && alias.table.functions.first?.offset == 2)
    #expect(alias.table.entries[1].kind.isValue)

    // The same file with the first name changed: no entry holds the handler under its own name.
    let changed = try normalize(document(tableVector([(bytes("hexper"), .vector(helper))])))
    #expect(changed.table.functions.count == 1)
    let two = try normalize(document(tableVector([(bytes("a"), .vector(helper)), (bytes("b"), .vector(helper))])))
    #expect(two.table.functions.count == 2)

    // The definition can be in another table: here the alias is in a script object.
    let inner = tableVector([(bytes("h"), .vector(helper))])
    let object = wrapperVector(bytes("inner"), parent: .null, table: inner)
    let script = try normalize(document(tableVector([(bytes("helper"), .vector(helper)), (bytes("inner"), .vector(object))])))
    #expect(script.table.functions.count == 1)
    let found = try #require(script.table.scriptObjects.first)
    #expect(found.functions.isEmpty && found.entries.first?.kind.isValue == true)
}

/**
 The value of `property parent` is made when the source is compiled. It
 can be a whole script that no entry of the file defines:

 ```
 property parent : load script file "library.scpt"
 ```

 Its handlers are then in the parent slot only, and must be found.
 */
@Test func `a script object held only as a parent is found`() throws {
    let library = wrapperVector(.null, parent: .secondActor, table: tableVector([(bytes("secret"), .vector(handlerVector("secret")))]))
    let script = try normalize(document(tableVector([(bytes("main"), .vector(handlerVector("main")))]), parent: .vector(library)))
    #expect(script.table.functions.map(\.name) == [bytes("main")])
    #expect(script.table.parentObjects.count == 1)
    let parent = try #require(script.table.scriptObjects.first)
    #expect(parent.functions.map(\.name) == [bytes("secret")])
    #expect(parent.path == "root.parent.vector[4]" && parent.name == nil)
    #expect(script.allScriptObjects.count == 1)

    // The same for the parent of a script object, at any depth.
    let child = wrapperVector(bytes("child"), parent: .vector(library), table: tableVector([(bytes("go"), .vector(handlerVector("go")))]))
    let nested = try normalize(document(tableVector([(bytes("child"), .vector(child))])))
    let found = try #require(nested.table.scriptObjects.first)
    #expect(found.parentObjects.count == 1 && found.scriptObjects.first?.functions.first?.name == bytes("secret"))
    #expect(nested.allScriptObjects.count == 2)
}

/** A parent that an entry defines is found at that entry, once, whatever the order of the entries. */
@Test func `a parent defined by an entry stays at its place`() throws {
    let base = wrapperVector(bytes("base"), parent: .null, table: tableVector([(bytes("f"), .vector(handlerVector("f")))]))
    let child = wrapperVector(bytes("child"), parent: .vector(base), table: tableVector([(bytes("g"), .vector(handlerVector("g")))]))
    for entries in [[("base", base), ("child", child)], [("child", child), ("base", base)]] {
        let script = try normalize(document(tableVector(entries.map { (bytes($0.0), .vector($0.1)) })))
        #expect(script.table.scriptObjects.count == 2)
        #expect(script.allScriptObjects.count == 2)
        #expect(script.table.scriptObjects.flatMap(\.parentObjects).isEmpty)
        let found = try #require(script.table.scriptObjects.first { $0.name == bytes("child") })
        #expect(found.parent?.vector === base)
    }
}

/**
 A very long list as the value of a property. The search does not call
 itself for each cell, and makes the text of a place only for a table it
 finds: here the one script object, at the end of the list.
 */
@Test func `a long list is searched without deep recursion`() throws {
    let object = wrapperVector(bytes("last"), parent: .null, table: tableVector([(bytes("f"), .vector(handlerVector("f")))]))
    var list = Pair(head: .vector(object), tail: .pair(Pair(empty: true)))
    for index in 0 ..< 200_000 {
        list = Pair(head: .integer(Int64(index)), tail: .pair(list))
    }
    let script = try normalize(document(tableVector([(bytes("big"), .pair(list))])))
    let found = try #require(script.table.scriptObjects.first)
    #expect(found.functions.count == 1)
    #expect(found.path.hasPrefix("root[2].tail.tail.") && found.path.hasSuffix(".tail.head.vector[4]"))
    #expect(found.path.split(separator: ".").count == 200_003)
}

/** The items of a typed vector skip its slot 0, and follow a change of the vector. */
@Test func `the items of a vector`() {
    let plain = Vector(children: [.integer(1), .integer(2)])
    #expect(plain.items == [.integer(1), .integer(2)] && plain.itemCount == 2)
    let typed = Vector(type: 4, hasType: true, children: [.null, .integer(1), .integer(2)])
    #expect(typed.items == [.integer(1), .integer(2)] && typed.itemCount == 2)
    typed.children.append(.integer(3))
    #expect(typed.items == [.integer(1), .integer(2), .integer(3)] && typed.itemCount == 3)
    typed.hasType = false
    #expect(typed.items.count == 4)
    #expect(Vector(type: 4, hasType: true).items.isEmpty && Vector(type: 4, hasType: true).itemCount == 0)
}
