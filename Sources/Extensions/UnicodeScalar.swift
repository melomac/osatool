package extension Unicode.Scalar {
    /** True for a letter (general category L). */
    var isLetter: Bool {
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            true
        default:
            false
        }
    }

    /** True for a decimal digit (general category Nd). */
    var isDecimalDigit: Bool {
        properties.generalCategory == .decimalNumber
    }

    /**
     True for a character that can be shown as it is: a letter, a mark, a
     number, punctuation, a symbol, or the ASCII space. Other spaces and
     control characters are not printable.
     */
    var isPrintable: Bool {
        if self == " " {
            return true
        }
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
