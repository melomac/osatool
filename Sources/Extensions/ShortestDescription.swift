package extension Double {
    /**
     The number written with the shortest digits that read back as the
     same number.

     ```
     exponent < -4  or  exponent >= 6   ->  d.ddde±XX   (1e-05, 1e+06)
     otherwise                          ->  plain form  (0.0001, 999999, 3)
     ```

     A whole number has no fraction part: `3.0` gives `"3"`.
     */
    var shortestDescription: String {
        if isNaN {
            return "NaN"
        }
        if isInfinite {
            return self < 0 ? "-Inf" : "+Inf"
        }
        let (digits, point) = self.shortestDigits
        let zero = UInt8(ascii: "0")
        var out: [UInt8] = sign == .minus ? [UInt8(ascii: "-")] : []
        let scientific = point - 1
        if scientific < -4 || scientific >= 6 {
            out.append(digits.first ?? zero)
            if digits.count > 1 {
                out.append(UInt8(ascii: "."))
                out.append(contentsOf: digits[1...])
            }
            out.append(UInt8(ascii: "e"))
            let shown = digits.isEmpty ? 0 : scientific
            out.append(UInt8(ascii: shown < 0 ? "-" : "+"))
            let size = String(abs(shown))
            if size.utf8.count < 2 {
                out.append(zero)
            }
            out.append(contentsOf: size.utf8)
            return String(decoding: out, as: UTF8.self)
        }
        if point > 0 {
            for index in 0 ..< point {
                out.append(index < digits.count ? digits[index] : zero)
            }
        } else {
            out.append(zero)
        }
        let fraction = max(digits.count - point, 0)
        if fraction > 0 {
            out.append(UInt8(ascii: "."))
            for index in 0 ..< fraction {
                let position = point + index
                out.append(position >= 0 && position < digits.count ? digits[position] : zero)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /**
     The shortest digits that read back as the same number, and the
     place of the decimal point: the number is `0.DIGITS × 10^point`,
     without its sign. Zero has no digit.

     ```
     1234.5   ->  12345, 4        0.00012  ->  12, -3        100  ->  1, 3
     ```
     */
    var shortestDigits: (digits: [UInt8], point: Int) {
        // Swift's description already holds the shortest round-trip digits.
        // Only the digits and the decimal point position are taken from it.
        var text = Substring(magnitude.description)
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: marker)...]) ?? 0
            text = text[..<marker]
        }
        var digits: [UInt8] = []
        var point = 0
        var seenPoint = false
        for unit in text.utf8 {
            if unit == UInt8(ascii: ".") {
                seenPoint = true
                continue
            }
            digits.append(unit)
            if !seenPoint {
                point += 1
            }
        }
        point += exponent
        while let first = digits.first, first == UInt8(ascii: "0") {
            digits.removeFirst()
            point -= 1
        }
        while let last = digits.last, last == UInt8(ascii: "0") {
            digits.removeLast()
        }
        if digits.isEmpty {
            point = 0
        }
        return (digits, point)
    }
}
