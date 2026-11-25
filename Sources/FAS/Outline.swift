import Extensions

package extension Document {
    /**
     Every value of the document as text, one on each line, with
     nothing left out. Two scripts with the same outline hold the same
     data: the same code, literals, names, properties and script
     objects.

     ```
     root: vector #1 type=15 [5]
       vector[0]: integer 1
       vector[1]: null
       vector[4]: vector #2 [3]
         vector[0]: null
         vector[1]: vector #3 [1]
           vector[0]: bytes "run"
     ```

     A container has a number, given when it is first met. When it is
     met again, by a shared use or by a loop, only the number is
     written: `vector[2]: see #2`.

     The lines are indented to show what is inside what, up to 40
     levels: a long list is a chain of pairs, each inside the one before.

     - `comparable`: leave out what two scripts made from the same
       source at two moments, or laid out in two ways, do not share:

       ```
       the tree of an editable script     kept to print its text; a run-only script has none
       the tree of a script object        made in a handler: it has its empty lines and
                                          its parentheses; the code made from it is compared
       the content of an alias            dates and numbers of the file system
       ```
     */
    func outline(comparable: Bool = false) -> String {
        var lines: [String] = []
        var numbers: [ObjectIdentifier: Int] = [:]
        // The values still to write, the last one first.
        var pending: [(place: String, value: Value, depth: Int)] = [("root", self.root, 0)]
        while let (place, value, depth) = pending.popLast() {
            let margin = String(repeating: "  ", count: min(depth, 40))
            if comparable, case .statement = value {
                // The script and each handler keep their tree in slot 2.
                lines.append("\(margin)\(place): " + (place == "vector[2]" ? "null" : "statement"))
                continue
            }
            var number = 0
            if let node = value.node {
                if let known = numbers[ObjectIdentifier(node)] {
                    lines.append("\(margin)\(place): see #\(known)")
                    continue
                }
                number = numbers.count + 1
                numbers[ObjectIdentifier(node)] = number
            }
            lines.append("\(margin)\(place): \(value.outlineLine(number, comparable))")
            for child in value.children.reversed() {
                pending.append((child.place, child.value, depth + 1))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension Value {
    /** One line for the value itself, without what is inside it. */
    func outlineLine(_ number: Int, _ comparable: Bool) -> String {
        switch self {
        case .null: "null"
        case let .boolean(value): "boolean \(value)"
        case let .integer(value): "integer \(value)"
        case let .real(value): "real \(value.bitPattern.hex(width: 16))"
        case let .special(value): "special \(value)"
        case let .constant(value): "constant \(value.hex(width: 16))"
        case .secondActor: "second actor"
        case let .bytes(bytes): "bytes \(bytes.quoted)"
        case let .unicodeText(text): "unicode text \(text.text.hex) style \(text.style.hex)"
        case let .rawData(bytes): "raw data \(bytes.hex)"
        case let .typedData(data): "typed data \(data.type) \(data.data.hex)"
        case let .descriptor(descriptor):
            "descriptor \(descriptor.type.bytes.quoted)" + (comparable && descriptor.type == "alis" ? "" : " \(descriptor.content.hex)")
        case let .eventIdentifier(event): "event " + event.fields.map(\.bytes.hex).joined(separator: " ")
        case .object: "object"
        case let .pair(pair): "pair #\(number)" + (pair.empty ? " empty" : "")
        case let .binding(binding): "binding #\(number)" + (binding.empty ? " empty" : "")
        case let .vector(vector): "vector #\(number)" + (vector.hasType ? " type=\(vector.type)" : "") + " [\(vector.children.count)]"
        case let .statement(statement):
            "statement #\(number) tag=\(statement.tag) type=\(statement.typeInfo) \(statement.start)-\(statement.end) [\(statement.children.count)]"
        }
    }
}
