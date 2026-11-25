import FAS
import Model
import Testing
import TestSupport

/** Reads a script of `testdata` and returns its function tables. */
private func model(_ relativePath: String) throws -> CompiledScript {
    try normalize(parse(TestData.bytes(relativePath), options: ParseOptions(strict: true)))
}

private func name(_ table: ScriptTable) -> String {
    table.name?.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

/**
 The script objects are kept as a tree, like the source:

 ```
 script helper … end script
 script main
     script inner … end script
 end script
 ```
 */
@Test func `a script object inside another one is kept inside it`() throws {
    let script = try model("backrefs/sibling_script_objects.scpt")
    #expect(script.table.scriptObjects.map(name) == ["helper", "main"])

    let main = script.table.scriptObjects[1]
    #expect(main.scriptObjects.map(name) == ["inner"])
    // `inner` is the first entry of the table of `main`.
    #expect(main.scriptObjects.first?.entryOffset == 2)
    #expect(main.scriptObjects.first?.scriptObjects.isEmpty == true)

    // The flat list has every script object, the outer one first.
    #expect(script.allScriptObjects.map(name) == ["helper", "main", "inner"])
}

/**
 Each table keeps a link to the table around it. The search must not
 follow that link, or the root would be found again as a script object.
 */
@Test func `a table is linked to the table around it`() throws {
    let script = try model("backrefs/sibling_script_objects.scpt")
    let main = script.table.scriptObjects[1]
    let inner = try #require(main.scriptObjects.first)
    #expect(main.raw.children.first?.vector === script.table.raw)
    #expect(inner.raw.children.first?.vector === main.raw)
}

@Test func `the parent property points to the wrapper of the parent`() throws {
    let script = try model("backrefs/script_object_parent.scpt")
    #expect(script.table.scriptObjects.map(name) == ["base", "derived"])
    // `base` has no `property parent`: its parent slot holds the root.
    #expect(script.table.scriptObjects[0].parent == nil)
    let base = try #require(script.table.raw.children[script.table.scriptObjects[0].entryOffset].vector)
    #expect(base.children[3].vector === script.top)

    // The wrapper is the entry of the root table that holds `base`.
    let wrapper = try #require(script.table.scriptObjects[1].parent?.vector)
    #expect(wrapper === script.table.raw.children[script.table.scriptObjects[0].entryOffset].vector)
    #expect(wrapper.children.last?.vector === script.table.scriptObjects[0].raw)
}

/**
 A script object with no `property parent` stores the root as its parent,
 at any depth: `inner` is inside `main`, and its parent slot is the root
 wrapper, not the wrapper of `main`. The file stores a reference to 0.
 */
@Test func `the default parent of a script object is the root`() throws {
    let script = try model("backrefs/sibling_script_objects.scpt")
    let main = script.table.scriptObjects[1]
    let inner = try #require(main.scriptObjects.first)
    #expect(script.table.parent == nil && main.parent == nil && inner.parent == nil)

    let mainWrapper = try #require(script.table.raw.children[main.entryOffset].vector)
    #expect(mainWrapper.children[3].vector === script.top)
    let innerWrapper = try #require(main.raw.children[inner.entryOffset].vector)
    #expect(innerWrapper.children[3].vector === script.top)
    #expect(innerWrapper.children[4].vector === inner.raw)
}

/**
 A script object with properties only has no function. It is still a
 script object, and the search does not go through it back to the root.
 */
@Test func `a script object without handlers is found once`() throws {
    let script = try model("compiled/script_object_without_handlers.scpt")
    #expect(script.table.scriptObjects.map(name) == ["settings", "finderChild", "child"])
    #expect(script.table.scriptObjects[0].functions.isEmpty)
    #expect(script.table.scriptObjects.allSatisfy { $0.scriptObjects.isEmpty })
    #expect(script.allScriptObjects.count == 3)
    // The parent of `finderChild` is an application, not a script object.
    #expect(script.table.scriptObjects[1].parent != nil)
    #expect(script.table.scriptObjects[1].parent?.vector?.type != 15)
}

/** Returns one word for the kind of an entry, with what it holds. */
private func kind(_ entry: Entry) -> String {
    switch entry.kind {
    case let .function(function):
        "function at \(function.offset)"
    case let .scriptObjects(tables):
        "script " + tables.map(name).joined(separator: ", ")
    case .value:
        "value"
    }
}

/**
 Each entry of a table is classified once: a function, script objects,
 or a plain value. The entries keep the order of the table, and each one
 has its name from the name table.
 */
@Test func `the entries of a table are typed`() throws {
    // script helper, script main (with script inner), on run argv
    let script = try model("backrefs/sibling_script_objects.scpt")
    let table = script.table
    #expect(table.path == "root")
    #expect(table.entries.map(\.offset) == [2, 3, 4])
    #expect(table.entries.map(kind) == ["script helper", "script main", "function at 4"])
    #expect(table.entries.map(\.name) == table.names)
    #expect(table.functions.count == 1)

    let main = table.scriptObjects[1]
    #expect(main.path == "root[3].vector[4]")
    #expect(main.entries.first.map(kind) == "script inner")
    // A function knows the entry that holds it.
    for entry in main.entries {
        if case let .function(function) = entry.kind {
            #expect(function.offset == entry.offset)
            #expect(entry.value.vector === function.raw)
        }
    }

    // Properties are plain values.
    let settings = try model("compiled/script_object_without_handlers.scpt").table.scriptObjects[0]
    #expect(settings.entries.map(kind) == ["value", "value"])
}

/** At the top level, the value of `property parent` is kept beside the table. */
@Test func `the top level parent is read from the wrapper of the script`() throws {
    let script = try model("compiled/top_level_parent.scpt")
    #expect(script.table.parent != nil)
    // A script without the property has none.
    let other = try model("compiled/labeled_handlers.scpt")
    #expect(other.table.parent == nil)
}

/**
 A function keeps its labeled parameters as a chain of bindings:
 `on polish to x` has one, from the code of `to` to the name `x`.
 */
@Test func `a function keeps its labeled parameters`() throws {
    let script = try model("compiled/labeled_handlers.scpt")
    let polish = try #require(script.table.functions.first { $0.name == .bytes(Array("polish".utf8)) })
    let binding = try #require(polish.labels.binding)
    #expect(binding.key == .object(.constant(0x746f_2020)))
    #expect(binding.value == .bytes(Array("x".utf8)))
    #expect(binding.next.binding == nil)

    // A positional handler has no label: the slot holds an empty list cell.
    let mix = try #require(script.table.functions.first { $0.name == .bytes(Array("mix".utf8)) })
    #expect(mix.labels.pair?.empty == true)
    #expect(mix.arguments.vector != nil)
}

/** A script object with nothing in it is still a script object. */
@Test func `an empty script object is found`() throws {
    let script = try model("compiled/declaration_order.scpt")
    let table = script.table
    #expect(table.scriptObjects.map(name) == ["base", "s"])
    #expect(table.scriptObjects[0].entries.isEmpty)
    #expect(table.scriptObjects[1].scriptObjects.map(name) == ["t"])
    // The entries are in the order of the source.
    #expect(table.entries.map(kind) == ["script base", "value", "value", "function at 5", "script s", "value", "function at 8"])
}
