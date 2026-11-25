/**
 A small JSON tree and its writer.

 The writer keeps the keys in the order they are given and indents with
 two spaces. A value inside `.line` is written on one line, with all
 that it holds: a file that people compare line by line uses it for
 its entries.

 ```
 {
   "schema_version": 1,
   "terms": [
     { "code": "pnam", "name": "name" },
     { "code": "pcnt", "name": "contents" }
   ]
 }
 ```
 */
package indirect enum JSONValue {
    case number(Int)
    case boolean(Bool)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])
    /** A value written on one line. */
    case line(JSONValue)

    /**
     The tree as text, ending with a line feed.

     - `escapesHTML`: see `String.jsonQuoted(escapesHTML:)`.
     - `compact`: write all on one line and without a space, for a file
       that only a program reads: `{"key":[1,2]}`.
     */
    package func text(escapesHTML: Bool = false, compact: Bool = false) -> String {
        var out = ""
        if compact {
            self.writeLine(to: &out, escapesHTML: escapesHTML, compact: true)
        } else {
            self.write(to: &out, indent: 0, escapesHTML: escapesHTML)
        }
        return out + "\n"
    }

    /** Writes the value on several lines. `indent` is the depth of the line it starts on. */
    private func write(to out: inout String, indent: Int, escapesHTML: Bool) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closingPad = String(repeating: "  ", count: indent)
        switch self {
        case .number, .boolean, .string, .line:
            self.writeLine(to: &out, escapesHTML: escapesHTML)
        case let .array(items):
            if items.isEmpty {
                out += "[]"
                return
            }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.write(to: &out, indent: indent + 1, escapesHTML: escapesHTML)
                out += index + 1 < items.count ? ",\n" : "\n"
            }
            out += closingPad + "]"
        case let .object(fields):
            if fields.isEmpty {
                out += "{}"
                return
            }
            out += "{\n"
            for (index, field) in fields.enumerated() {
                out += pad + field.0.jsonQuoted(escapesHTML: escapesHTML) + ": "
                field.1.write(to: &out, indent: indent + 1, escapesHTML: escapesHTML)
                out += index + 1 < fields.count ? ",\n" : "\n"
            }
            out += closingPad + "}"
        }
    }

    /**
     Writes the value on one line: `[1, 2]`, `{ "key": 1, "other": 2 }`.
     The compact form has no space: `[1,2]`, `{"key":1,"other":2}`.
     */
    private func writeLine(to out: inout String, escapesHTML: Bool, compact: Bool = false) {
        switch self {
        case let .number(value):
            out += String(value)
        case let .boolean(value):
            out += value ? "true" : "false"
        case let .string(value):
            out += value.jsonQuoted(escapesHTML: escapesHTML)
        case let .line(value):
            value.writeLine(to: &out, escapesHTML: escapesHTML, compact: compact)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                out += index > 0 ? (compact ? "," : ", ") : ""
                item.writeLine(to: &out, escapesHTML: escapesHTML, compact: compact)
            }
            out += "]"
        case let .object(fields):
            if fields.isEmpty {
                out += "{}"
                return
            }
            out += compact ? "{" : "{ "
            for (index, field) in fields.enumerated() {
                out += (index > 0 ? (compact ? "," : ", ") : "") + field.0.jsonQuoted(escapesHTML: escapesHTML) + (compact ? ":" : ": ")
                field.1.writeLine(to: &out, escapesHTML: escapesHTML, compact: compact)
            }
            out += compact ? "}" : " }"
        }
    }
}

package extension String {
    /**
     The text as a JSON string, between quotes. Control characters are
     written as escapes.

     - `escapesHTML`: also write `<`, `>`, `&`, U+2028 and U+2029 as
       escapes, which keeps the output safe to paste inside HTML or
       JavaScript.
     */
    func jsonQuoted(escapesHTML: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        out.append("\"")
        for scalar in self.unicodeScalars {
            switch scalar {
            case "\\":
                out.append(contentsOf: "\\\\".unicodeScalars)
            case "\"":
                out.append(contentsOf: "\\\"".unicodeScalars)
            case "\u{08}":
                out.append(contentsOf: "\\b".unicodeScalars)
            case "\u{0C}":
                out.append(contentsOf: "\\f".unicodeScalars)
            case "\n":
                out.append(contentsOf: "\\n".unicodeScalars)
            case "\r":
                out.append(contentsOf: "\\r".unicodeScalars)
            case "\t":
                out.append(contentsOf: "\\t".unicodeScalars)
            case "<", ">", "&", "\u{2028}", "\u{2029}":
                if escapesHTML {
                    out.append(contentsOf: ("\\u" + scalar.value.hex(width: 4)).unicodeScalars)
                } else {
                    out.append(scalar)
                }
            case _ where scalar.value < 0x20:
                out.append(contentsOf: ("\\u" + scalar.value.hex(width: 4)).unicodeScalars)
            default:
                out.append(scalar)
            }
        }
        out.append("\"")
        return String(out)
    }
}
