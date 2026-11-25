package extension Sequence<UInt8> {
    /** The bytes as lowercase hexadecimal text: `[0x0a, 0xff]` gives `"0aff"`. */
    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

package extension BinaryInteger {
    /** The number as lowercase hexadecimal text: `255` gives `"ff"`. */
    var hex: String {
        hex(width: 0)
    }

    /**
     The number as lowercase hexadecimal text, with zeros added on the
     left up to `width` characters: `5.hex(width: 4)` gives `"0005"`.
     */
    func hex(width: Int) -> String {
        let negative = self < 0
        var text = String(magnitude, radix: 16)
        let digits = width - (negative ? 1 : 0)
        if text.count < digits {
            text = String(repeating: "0", count: digits - text.count) + text
        }
        return negative ? "-" + text : text
    }
}

package extension [UInt8] {
    /**
     Decodes hexadecimal text into bytes. Upper and lower case digits are
     accepted.

     The result is `nil` when the text has an odd length or holds a
     character that is not a hexadecimal digit.
     */
    init?(hex text: String) {
        let units = Array(text.utf8)
        guard units.count % 2 == 0 else { return nil }
        func nibble(_ unit: UInt8) -> UInt8? {
            switch unit {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): unit - UInt8(ascii: "0")
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): unit - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): unit - UInt8(ascii: "A") + 10
            default: nil
            }
        }
        var out: [UInt8] = []
        out.reserveCapacity(units.count / 2)
        var index = 0
        while index < units.count {
            guard
                let high = nibble(units[index]),
                let low = nibble(units[index + 1])
            else {
                return nil
            }
            out.append(high << 4 | low)
            index += 2
        }
        self = out
    }
}
