import Extensions
import FAS

extension Value {
    /**
     A short, one-line description of the stored value.

     The disassembler uses it for function names and for the comment next to
     an instruction that loads a literal:

     ```
     "name"                  a printable byte string, or Unicode text,
                             or a text object (a vector of class 177)
     0x00ff…                 a byte string that is not printable
     constant(0x706e616d)    a packed code
     event("aevt","oapp",…)  an event identifier
     vector(type=16,len=7)   another container, not expanded
     ```
     */
    var summary: String {
        switch self {
        case .null:
            return "nil"
        case let .boolean(flag):
            return flag ? "true" : "false"
        case let .integer(number):
            return String(number)
        case let .real(number):
            return number.shortestDescription
        case let .special(code):
            return "special(0x\(code.hex))"
        case let .constant(code):
            return "constant(0x\(code.hex))"
        case let .bytes(data):
            return data.isPrintableASCII ? data.quoted : "0x" + data.hex
        case let .unicodeText(text):
            // Styled text is MacRoman: see `UnicodeText`.
            return text.style.isEmpty ? text.text.quotedUTF16 : String(macRoman: text.text).quoted
        case let .object(content):
            return content.summary
        case let .rawData(data):
            return "data[\(data.count)](\(data.hexPreview))"
        case let .typedData(data):
            return "typed-data[\(data.type)](\(data.data.hexPreview))"
        case let .descriptor(descriptor):
            return "descriptor(\(descriptor.type.bytes.quoted),\(descriptor.content.hexPreview))"
        case let .eventIdentifier(event):
            return "event(" + event.fields.map { $0.bytes.isPrintableASCII ? $0.bytes.quoted : "0x" + $0.bytes.hex }.joined(separator: ",") + ")"
        case let .pair(pair):
            return pair.empty ? "[]" : "pair(" + pair.head.summary + ",...)"
        case let .binding(binding):
            return binding.empty ? "{}" : "binding(" + binding.key.summary + ",...)"
        case let .vector(vector):
            if let text = vector.storedText {
                return text.quotedUTF16
            }
            if vector.hasType {
                return "vector(type=\(vector.type),len=\(vector.children.count - 1))"
            }
            return "vector(len=\(vector.children.count))"
        case let .statement(statement):
            return "statement(type=\(statement.typeInfo),span=\(statement.start):\(statement.end))"
        case .secondActor:
            return "second-actor"
        }
    }
}

extension Vector {
    /**
     The UTF-16 bytes of a text object, or `nil` for any other vector.

     A text literal of a script is not a bare string: it is a vector of
     class 177 with the text at child 1.
     */
    var storedText: [UInt8]? {
        guard
            self.hasType,
            self.type == 177,
            self.children.count > 1
        else {
            return nil
        }
        switch self.children[1] {
        case let .bytes(data):
            return data
        case let .unicodeText(text):
            return text.text
        default:
            return nil
        }
    }
}

extension [UInt8] {
    /**
     Stored UTF-16 big-endian text as a quoted string.

     Data with an odd length cannot be UTF-16: its bytes are quoted as
     they are.
     */
    var quotedUTF16: String {
        self.count % 2 == 0 ? String(utf16BigEndian: self).quoted : self.quoted
    }

    /** The first 24 bytes as hexadecimal, with `...` when there are more. */
    var hexPreview: String {
        let limit = 24
        return count <= limit ? hex : self[..<limit].hex + "..."
    }
}
