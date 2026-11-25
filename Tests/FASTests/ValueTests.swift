import Extensions
import FAS
import Testing

/** Small values are equal by content; containers only when they are the same object. */
@Test func `value equality`() {
    #expect(Value.integer(7) == .integer(7))
    #expect(Value.integer(7) != .integer(8))
    #expect(Value.integer(1) != .boolean(true))
    #expect(Value.bytes([1, 2]) == .bytes([1, 2]))
    #expect(Value.object(.constant(0x706e_616d)) == .object(.constant(0x706e_616d)))
    #expect(Value.object(.constant(1)) != .constant(1))
    #expect(Value.null.isNull)
    #expect(!Value.secondActor.isNull)

    let vector = Vector(children: [.integer(1)])
    let twin = Vector(children: [.integer(1)])
    #expect(Value.vector(vector) == .vector(vector))
    #expect(Value.vector(vector) != .vector(twin))
    #expect(Value.object(.vector(vector)) == .object(.vector(vector)))
    #expect(Value.pair(Pair(empty: true)) != .pair(Pair(empty: true)))
}

@Test func `reading one case`() {
    let vector = Vector()
    #expect(Value.bytes([65]).bytes == [65])
    #expect(Value.integer(65).bytes == nil)
    #expect(Value.vector(vector).vector === vector)
    #expect(Value.null.vector == nil)
    #expect(Value.object(.integer(3)).object == .integer(3))
    #expect(Value.constant(9).constant == 9)
    // A constant inside an object is not a bare constant.
    #expect(Value.object(.constant(9)).constant == nil)
}

@Test func `type names`() {
    #expect(Value.null.typeName == "nil")
    #expect(Value.real(1.5).typeName == "float")
    #expect(Value.unicodeText(UnicodeText()).typeName == "unicode-text")
    #expect(Value.vector(Vector()).typeName == "vector")
    // No value at all is not the stored nil.
    #expect(Value?.none.typeName == "nothing")
    #expect(Value?.some(.null).typeName == "nil")
}

/** The places are the words used in the path of a script object. */
@Test func `children and their places`() {
    func places(_ value: Value) -> [String] {
        value.children.map(\.place)
    }
    #expect(places(.integer(1)).isEmpty)
    #expect(places(.object(.integer(1))) == ["object"])
    #expect(places(.pair(Pair())) == ["head", "tail"])
    #expect(places(.binding(Binding())) == ["key", "value", "extra", "next"])
    #expect(places(.vector(Vector(children: [.null, .integer(2)]))) == ["vector[0]", "vector[1]"])
    #expect(places(.statement(Statement(children: [.null]))) == ["statement[0]"])

    let pair = Value.pair(Pair(head: .integer(1), tail: .integer(2)))
    #expect(pair.children.map(\.value) == [.integer(1), .integer(2)])
    #expect(Value.object(.integer(5)).children.first?.value == .integer(5))
}

@Test func `a walk enters a container once`() {
    let vector = Vector()
    let value = Value.vector(vector)
    var visited = Visited()
    // Each call says whether the walk may enter.
    var answers = [visited.enter(value), visited.enter(value), visited.enter(vector)]
    #expect(answers == [true, false, false])
    #expect(visited.contains(vector))

    // Another container with the same content is another node.
    answers = [visited.enter(.vector(Vector()))]
    #expect(answers == [true])

    // A value that is not a container can always be entered.
    answers = [
        visited.enter(.integer(1)), visited.enter(.integer(1)),
        visited.enter(.object(.integer(1))), visited.enter(.object(.integer(1))),
    ]
    #expect(answers == [true, true, true, true])

    // After `leave`, the container can be entered again.
    visited.leave(value)
    #expect(!visited.contains(vector))
    answers = [visited.enter(value)]
    #expect(answers == [true])
}

/**
 A loop in the graph: a vector that holds a pair whose tail is the
 vector. A walk with `Visited` ends, and sees each container once.
 */
@Test func `a walk of a graph with a loop ends`() {
    let vector = Vector()
    let pair = Pair(head: .integer(1), tail: .vector(vector))
    vector.children = [.pair(pair), .pair(pair), .bytes([1])]
    defer { vector.children = [] }

    var visited = Visited()
    var entered: [String] = []
    func walk(_ value: Value) {
        guard visited.enter(value) else {
            return
        }
        entered.append(value.typeName)
        value.children.forEach { walk($0.value) }
    }
    walk(.vector(vector))
    #expect(entered == ["vector", "pair", "integer", "bytes"])
}

/**
 The four last fields of an event say how the source named it. With no
 dictionary the compiler writes the same values every time.
 */
@Test func `an event named by its code has the default description`() {
    func event(_ third: Code4, _ flags: UInt32, _ fifth: Code4, _ last: UInt32) -> EventIdentifier {
        EventIdentifier(fields: ["emal", "cpma", third, Code4(rawValue: flags), fifth, Code4(rawValue: last)])
    }
    #expect(event("****", 0, "****", 0x9000).isRawForm)
    #expect(!event("null", 0xffff_8000, "****", 0).isRawForm)
    #expect(!event("null", 0x8000, "****", 0x9000).isRawForm)
    #expect(!EventIdentifier().isRawForm)
    #expect(event("****", 0, "****", 0x9000).code == "emalcpma")
}
