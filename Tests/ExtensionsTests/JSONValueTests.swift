import Extensions
import Testing

/**
 The writer keeps the order of the keys and indents with two spaces. A
 value inside `.line` is on one line, with all that it holds.
 */
@Test func `JSON is written on several lines, and a line value on one`() {
    let value = JSONValue.object([
        ("version", .number(1)),
        ("empty", .array([])),
        ("terms", .array([
            .line(.object([
                ("code", .string("pnam")),
                ("direct", .boolean(true)),
                ("parameters", .array([.object([("n", .number(-1))]), .number(2), .object([])])),
            ])),
            .string("a<b"),
            .array([.number(1), .boolean(false)]),
        ])),
        ("nothing", .object([])),
    ])
    #expect(value.text() == """
    {
      "version": 1,
      "empty": [],
      "terms": [
        { "code": "pnam", "direct": true, "parameters": [{ "n": -1 }, 2, {}] },
        "a<b",
        [
          1,
          false
        ]
      ],
      "nothing": {}
    }

    """)
    #expect(value.text(escapesHTML: true).contains(#""a\u003cb""#))
    #expect(JSONValue.number(7).text() == "7\n")
    #expect(value.text(compact: true) == """
    {"version":1,"empty":[],"terms":[{"code":"pnam","direct":true,"parameters":[{"n":-1},2,{}]},"a<b",[1,false]],"nothing":{}}

    """)
}

@Test func `JSON strings escape quotes and control characters`() {
    #expect("plain é".jsonQuoted() == "\"plain é\"")
    #expect("a\"b\\c".jsonQuoted() == #""a\"b\\c""#)
    #expect("\n\r\t\u{08}\u{0C}\u{01}\u{1F}".jsonQuoted() == #""\n\r\t\b\f\u0001\u001f""#)
}

/** `<`, `>`, `&` and the two line separators are escaped only on request. */
@Test func `JSON strings escape HTML characters on request`() {
    let text = "<&>\u{2028}\u{2029}"
    #expect(text.jsonQuoted() == "\"" + text + "\"")
    #expect(text.jsonQuoted(escapesHTML: true) == #""\u003c\u0026\u003e\u2028\u2029""#)
}
