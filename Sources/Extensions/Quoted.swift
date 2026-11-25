package extension [UInt8] {
    /**
     The bytes as a quoted string, for a listing or a message. Any content
     stays on one line and can be read without doubt.

     The bytes are read as UTF-8. Rules, in order:

     ```
     a byte that is not valid UTF-8      \xNN
     "  and  \                           \"  and  \\
     a printable character               written as it is
     bell, backspace, form feed, …       \a \b \f \n \r \t \v
     another control character           \xNN
     another character                   \uNNNN  or  \UNNNNNNNN
     ```
     */
    var quoted: String {
        var out = "\""
        var index = 0
        while index < count {
            guard let (scalar, width) = utf8Scalar(at: index) else {
                out += "\\x" + self[index].hex(width: 2)
                index += 1
                continue
            }
            index += width
            if scalar == "\"" || scalar == "\\" {
                out += "\\"
                out.unicodeScalars.append(scalar)
                continue
            }
            if scalar.isPrintable {
                out.unicodeScalars.append(scalar)
                continue
            }
            switch scalar.value {
            case 0x07: out += "\\a"
            case 0x08: out += "\\b"
            case 0x0c: out += "\\f"
            case 0x0a: out += "\\n"
            case 0x0d: out += "\\r"
            case 0x09: out += "\\t"
            case 0x0b: out += "\\v"
            case let value where value < 0x20 || value == 0x7f:
                out += "\\x" + value.hex(width: 2)
            case let value where value < 0x10000:
                out += "\\u" + value.hex(width: 4)
            case let value:
                out += "\\U" + value.hex(width: 8)
            }
        }
        return out + "\""
    }

    /**
     Decodes one UTF-8 character at `index`.

     - Returns: the character and the number of bytes it uses, or `nil`
       when the bytes at `index` are not valid UTF-8.
     */
    private func utf8Scalar(at index: Int) -> (scalar: Unicode.Scalar, width: Int)? {
        let available = count - index
        let first = self[index]
        if first < 0x80 {
            return (Unicode.Scalar(first), 1)
        }
        func continuation(_ offset: Int, _ low: UInt8 = 0x80, _ high: UInt8 = 0xbf) -> UInt32? {
            let byte = self[index + offset]
            return byte >= low && byte <= high ? UInt32(byte & 0x3f) : nil
        }
        switch first {
        case 0xc2 ... 0xdf:
            guard
                available >= 2,
                let second = continuation(1)
            else {
                return nil
            }
            return (Unicode.Scalar(UInt32(first & 0x1f) << 6 | second)!, 2)
        case 0xe0 ... 0xef:
            guard
                available >= 3,
                let second = continuation(1, first == 0xe0 ? 0xa0 : 0x80, first == 0xed ? 0x9f : 0xbf),
                let third = continuation(2)
            else {
                return nil
            }
            return (Unicode.Scalar(UInt32(first & 0x0f) << 12 | second << 6 | third)!, 3)
        case 0xf0 ... 0xf4:
            guard
                available >= 4,
                let second = continuation(1, first == 0xf0 ? 0x90 : 0x80, first == 0xf4 ? 0x8f : 0xbf),
                let third = continuation(2),
                let fourth = continuation(3)
            else {
                return nil
            }
            return (Unicode.Scalar(UInt32(first & 0x07) << 18 | second << 12 | third << 6 | fourth)!, 4)
        default:
            return nil
        }
    }
}

package extension String {
    /** The string as a quoted string. See `[UInt8].quoted` for the rules. */
    var quoted: String {
        Array(utf8).quoted
    }

    /** Adds spaces on the right until the string is `width` characters long. */
    func padded(to width: Int) -> String {
        let count = unicodeScalars.count
        return count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
