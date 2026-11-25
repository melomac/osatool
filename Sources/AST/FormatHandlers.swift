import Extensions
import Terminology

extension SourceFormatter {
    /**
     Prints one handler: its header, its statements, and its `end` line.
     See `handlerHeader` for the forms of the header.
     */
    func handler(_ handler: Handler, _ indent: Int) -> String {
        let prefix = self.margin(indent)
        if let (header, end) = self.colonHeader(handler) {
            return "\(prefix)on \(header)\n" + self.statements(handler.body, indent + 1) + "\(prefix)end \(end)"
        }
        let (name, parameters) = self.handlerHeader(handler)
        return "\(prefix)on \(name)\(parameters)\n" + self.statements(handler.body, indent + 1) + "\(prefix)end \(name)"
    }

    /**
     Prints a handler. One that answers a command of an application is
     printed inside `using terms from`, where the words of the command
     compile:

     ```
     using terms from application "Mail"
         on perform mail action with messages theMessages for rule theRule
             …
         end perform mail action with messages
     end using terms from
     ```

     Outside the handlers the block itself leaves nothing in the
     compiled script (inside one, see `UsingTerms`), but the event does: it says whether the source had the words or the code
     (see `EventIdentifier.isRawForm`). The dictionary that has the
     command gives the application. When no dictionary has it, or a
     label has no word, the raw form is printed.
     */
    func handlerBlock(_ handler: Handler, _ indent: Int) -> String {
        guard
            let code = handler.eventCode,
            !handler.isRunHandler,
            !handler.isRawEvent,
            let all = self.allTerms ?? self.terms,
            let application = all.application(of: code)
        else {
            return self.handler(handler, indent)
        }
        var inner = self
        inner.allTerms = all
        inner.terms = all.scoped(to: application)
        inner.usingTerms = true
        guard !inner.handlerHeader(handler).name.hasPrefix("«") else {
            return self.handler(handler, indent)
        }
        let prefix = self.margin(indent)
        return prefix + "using terms from application " + application.stringLiteral + "\n" + inner.handler(handler, indent + 1)
            + "\n" + prefix + "end using terms from"
    }

    /**
     Returns the header of a handler written with colons, and the name
     after `end`:

     ```
     on tableView:tv objectValueForTableColumn:c row:r
         …
     end tableView:objectValueForTableColumn:row:
     ```

     This is the form of a handler whose name has one `_` for each
     parameter: `tableView_objectValueForTableColumn_row_(tv, c, r)`.
     Apple's tools always print it with colons.

     - Returns: `nil` for any other handler.
     */
    func colonHeader(_ handler: Handler) -> (header: String, end: String)? {
        guard
            !handler.isRunHandler,
            handler.eventCode == nil,
            handler.name.hasSuffix("_"),
            !handler.parameters.isEmpty,
            handler.parameters.allSatisfy({ $0.label == nil })
        else {
            return nil
        }
        let parts = handler.name.split(separator: "_", omittingEmptySubsequences: false).dropLast()
        guard
            parts.count == handler.parameters.count,
            parts.allSatisfy({ !$0.isEmpty })
        else {
            return nil
        }
        // Before a colon too, a word of the language needs bars: `|error|:`, `|count|:`.
        let names = parts.map { self.name(String($0)) }
        let header = zip(names, handler.parameters).map { $0 + ":" + self.parameter($1) }.joined(separator: " ")
        return (header, names.map { $0 + ":" }.joined())
    }

    /**
     Returns the two parts of a handler header: the name, and the
     parameters with a space in front when there are some.

     ```
     on run argv                                     run handler
     on open theFiles                                event, no label
     on display dialog msg buttons btns              event, labels known
     on «event xxxxyyyy» direct given «class c»:v    event, other labels
     on name(a, b)                                   user handler
     on name of direct above x given flag:f          user handler, labels
     ```
     */
    func handlerHeader(_ handler: Handler) -> (name: String, parameters: String) {
        let labeled = handler.parameters.filter { $0.label != nil }
        let unlabeled = handler.parameters.filter { $0.label == nil }
        if handler.isRunHandler {
            return ("run", self.directParameters(unlabeled))
        }
        if let eventCode = handler.eventCode {
            return self.eventHeader(eventCode, unlabeled, labeled)
        }
        let name = self.name(handler.name)
        if labeled.isEmpty {
            return (name, "(" + unlabeled.map { self.parameter($0) }.joined(separator: ", ") + ")")
        }
        // `on |contained| by x`: see `before`.
        let parameters = self.labeledParameters(unlabeled.first, labeled)
        let barred = self.barring.labeledParameters(unlabeled.first, labeled)
        return (self.before(name, parameters.first ?? "", barred: self.barring.name(handler.name)), " " + self.parts(parameters, barred: barred))
    }

    /** Prints the parameters that have no label, each with a space in front. */
    func directParameters(_ unlabeled: [Parameter]) -> String {
        unlabeled.map { " " + self.parameter($0) }.joined()
    }

    /**
     Returns the header of a handler that answers an Apple event.

     The labels are printed as words only for a command that a script
     can use without a `tell` block. For a command of an application the
     words would not compile there, so the raw form is used, unless the
     handler is printed inside `using terms from` (see `handlerBlock`).
     */
    func eventHeader(_ eventCode: EventCode, _ unlabeled: [Parameter], _ labeled: [Parameter]) -> (name: String, parameters: String) {
        let direct = self.directParameters(unlabeled)
        if labeled.isEmpty {
            let command = self.terms?.scriptCommand(eventCode) ?? self.terms?.command(eventCode)
            return (command?.name ?? eventCode.rawEvent, direct)
        }
        if let command = self.usingTerms ? self.terms?.command(eventCode) : self.terms?.scriptCommand(eventCode),
           let words = self.eventParameters(command, unlabeled, labeled)
        {
            return (command.name, " " + self.parts(words, barred: self.barring.eventParameters(command, unlabeled, labeled) ?? words))
        }
        let given = labeled.map { self.givenLabel($0.label, raw: true) + ":" + self.parameter($0) }
        return (eventCode.rawEvent, direct + " given " + given.joined(separator: ", "))
    }

    /**
     The parameters of a handler that answers an Apple event, each
     labeled one with its word: `f`, `after receiving x`. `nil` when a
     label has no word.
     */
    func eventParameters(_ command: Command, _ unlabeled: [Parameter], _ labeled: [Parameter]) -> [String]? {
        let words = labeled.compactMap { parameter in
            parameter.code.flatMap { command.parameters[$0]?.name }.map { $0 + " " + self.parameter(parameter) }
        }
        return words.count == labeled.count ? unlabeled.map { self.parameter($0) } + words : nil
    }

    /**
     Prints the parameters of a user handler that has labels:

     ```
     on name of direct above x given flag:f
            └────────────────────────────┘
     ```

     A label that is a preposition is written before its parameter. The
     other labels come after `given`. Each group is one part of the
     result: `of direct`, `above x`, `given flag:f`.
     */
    func labeledParameters(_ direct: Parameter?, _ labeled: [Parameter]) -> [String] {
        var parameters = direct.map { ["of " + self.parameter($0)] } ?? []
        var given: [String] = []
        for parameter in labeled {
            if let word = parameter.code.flatMap({ handlerPrepositions[$0] }) {
                parameters.append(word + " " + self.parameter(parameter))
            } else {
                given.append(self.givenLabel(parameter.label) + ":" + self.parameter(parameter))
            }
        }
        if !given.isEmpty {
            parameters.append("given " + given.joined(separator: ", "))
        }
        return parameters
    }

    /** Prints what receives a parameter: a name, or a pattern such as `{a, b}`. */
    func parameter(_ parameter: Parameter) -> String {
        if let pattern = parameter.pattern {
            return self.expr(pattern)
        }
        return self.name(parameter.name)
    }

    /**
     Prints a label that is used after `given`, `with` or `without`.

     - `raw`: print a code as `«class xxxx»` also when the terminology
       has a word for it.
     */
    func givenLabel(_ label: Label?, raw: Bool = false) -> String {
        switch label {
        case let .word(word):
            return self.name(word)
        case let .code(code):
            if raw {
                return code.rawClass
            }
            return self.keyword(Keyword(code: .four(code)))
        case nil:
            return self.name("")
        }
    }
}

/**
 The prepositions that can label a parameter of a user handler, by
 their code. They are words of the language itself:

 ```
 on polish to x
 findNumbers of numberList above 1
 ```
 */
let handlerPrepositions: [Code4: String] = [
    "abou": "about", "abve": "above", "agst": "against", "aprt": "apart from", "arnd": "around",
    "asdf": "aside from", "at  ": "at", "belw": "below", "bnth": "beneath", "bsid": "beside",
    "btwn": "between", "by  ": "by", "for ": "for", "from": "from", "isto": "instead of",
    "into": "into", "on  ": "on", "onto": "onto", "outo": "out of", "over": "over",
    "snce": "since", "thgh": "through", "thru": "thru", "to  ": "to", "undr": "under",
]
