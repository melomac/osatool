import Extensions

// The small pieces of source text: a string, a name, a raw code.

extension String {
    /**
     The text as an AppleScript string literal, with its quotes.

     Only `\`, `"`, line feed, carriage return and tab are escaped. Every
     other character is written as it is, because AppleScript has no `\u`
     escape.
     */
    var stringLiteral: String {
        var out = String.UnicodeScalarView()
        out.append("\"")
        for scalar in self.unicodeScalars {
            switch scalar {
            case "\\":
                out.append(contentsOf: "\\\\".unicodeScalars)
            case "\"":
                out.append(contentsOf: "\\\"".unicodeScalars)
            case "\n":
                out.append(contentsOf: "\\n".unicodeScalars)
            case "\r":
                out.append(contentsOf: "\\r".unicodeScalars)
            case "\t":
                out.append(contentsOf: "\\t".unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        out.append("\"")
        return String(out)
    }

    /**
     The text as a user identifier.

     A name made of letters, digits and `_` (not starting with a digit), and
     which is not a reserved word, is written as is. Any other name is
     written between bars: `|my name|`.
     */
    var identifier: String {
        if self.isEmpty {
            return "|unnamed|"
        }
        var valid = !reservedWords.contains(self.lowercased())
        for (index, scalar) in self.unicodeScalars.enumerated() {
            if !(scalar.isLetter || scalar == "_" || (index > 0 && scalar.isDecimalDigit)) {
                valid = false
                break
            }
        }
        if valid {
            return self
        }
        // Between bars, a bar and a backslash are written after a backslash.
        var escaped = String.UnicodeScalarView()
        for scalar in self.unicodeScalars {
            if scalar == "|" || scalar == "\\" {
                escaped.append("\\")
            }
            escaped.append(scalar)
        }
        return "|" + String(escaped) + "|"
    }

    /**
     True for a text that is one pair of parentheses around all the
     rest: `(a + b)`, and not `(a) + (b)`, which only starts and ends
     with one. A parenthesis inside a text literal or between bars does
     not count.
     */
    var isParenthesized: Bool {
        guard
            self.hasPrefix("("),
            self.hasSuffix(")")
        else {
            return false
        }
        var depth = 0
        var quote: Character?
        var isEscaped = false
        var index = self.startIndex
        while index < self.endIndex {
            let character = self[index]
            index = self.index(after: index)
            if let open = quote {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "|" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                // The first parenthesis is closed: it must be at the end.
                if depth == 0 {
                    return index == self.endIndex
                }
            }
        }
        return false
    }
}

/**
 The first word of each keyword made of two words, when the word alone
 can be a name without bars, with the second words it joins with:
 `start with`, `contained by`, `apart from`, `out of`, `comes after`.
 `info for` is a command of Standard Additions.

 The first words of the other keywords of two words (`equal`, `back`,
 `relative`, …) always need bars: see `reserved_words` in
 `language.json`.
 */
let joiningWords: [String: Set<String>] = [
    "apart": ["from"], "aside": ["from"], "begin": ["with"], "begins": ["with"],
    "come": ["after", "before"], "comes": ["after", "before"], "contained": ["by"],
    "ends": ["with"], "info": ["for"], "instead": ["of"], "out": ["of"],
    "start": ["with"], "starts": ["with"],
]

/** The words that cannot be a user identifier without bars. */
let reservedWords: Set<String> = [
    "and", "as", "class", "considering", "continue", "copy", "else",
    "end", "error", "exit", "false", "from", "if", "in",
    "item", "items", "length", "local", "me", "missing", "name", "not", "of", "on", "or",
    "path", "property", "record", "repeat", "return", "script", "set", "tell",
    "then", "to", "true", "try", "whose", "with", "without",
]

extension [UInt8] {
    /**
     The bytes of a code, as they are written inside a raw form such as
     `«class pnam»`.

     Printable ASCII bytes and MacRoman letters are written as characters.
     When the code holds a control byte, the whole code is written as
     hexadecimal with a `0x` prefix.
     */
    var rawCode: String {
        var decoded = String.UnicodeScalarView()
        for byte in self {
            if byte >= 0x20, byte <= 0x7e {
                decoded.append(Unicode.Scalar(byte))
                continue
            }
            if byte < 0x20 || byte == 0x7f {
                return "0x" + self.hex
            }
            decoded.append(Unicode.Scalar(macRoman: byte))
        }
        return String(decoded)
    }
}

extension Code4 {
    /** The raw form of a class, a property or a label: `«class pnam»`. */
    var rawClass: String {
        "«class " + self.bytes.rawCode + "»"
    }

    /** The raw form of a property: `«property pnam»`. */
    var rawProperty: String {
        "«property " + self.bytes.rawCode + "»"
    }
}

extension EventCode {
    /** The raw form of a command: `«event aevtoapp»`. */
    var rawEvent: String {
        "«event " + self.bytes.rawCode + "»"
    }
}

extension [String] {
    /** The words joined as the language does: `a`, `a and b`, `a, b and c`. */
    var wordList: String {
        guard
            let last = self.last,
            self.count > 1
        else {
            return self.first ?? ""
        }
        return self.dropLast().joined(separator: ", ") + " and " + last
    }
}

extension Double {
    /**
     The number as a real in AppleScript source. It always has a
     decimal point, so that it is not read as an integer, and it is
     written the way Apple's tools write it:

     ```
     from 0.01 to 9999.99…    1.0    100.0    0.25    9999.0
     smaller or larger        1.0E+4    1.2345678E+4    1.0E-3    6.02E+23
     ```

     The digits are the shortest ones that read back as the same
     number. Apple's tools show about twelve, which can be another number.

     Zero keeps its sign: the compiler stores `-0.0` as it is written.

     No source gives a number that is not finite, so a compiler never
     stores one; a damaged file can. It is written as a mark, like
     `«real: infinity»`. The words `Inf` and `NaN` would read as the
     names of two variables.
     */
    var realLiteral: String {
        guard self.isFinite else {
            return self.isNaN ? "«real: not a number»" : (self.sign == .minus ? "«real: minus infinity»" : "«real: infinity»")
        }
        let (digits, point) = self.shortestDigits
        let sign = self.sign == .minus ? "-" : ""
        let text = String(decoding: digits, as: UTF8.self)
        if digits.isEmpty {
            return sign + "0.0"
        }
        let exponent = point - 1
        if exponent < -2 || exponent >= 4 {
            let fraction = text.dropFirst()
            return sign + text.prefix(1) + "." + (fraction.isEmpty ? "0" : fraction) + "E" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        }
        if point <= 0 {
            return sign + "0." + String(repeating: "0", count: -point) + text
        }
        if digits.count <= point {
            return sign + text + String(repeating: "0", count: point - digits.count) + ".0"
        }
        return sign + text.prefix(point) + "." + text.dropFirst(point)
    }
}
