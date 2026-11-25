package extension Int {
    /**
     Adds two numbers. When the sum does not fit, the result is the
     largest number (or the smallest one, for a negative sum).

     A count that can double many times is added this way, so that it
     stays "very large" and does not stop the program.
     */
    func addingSaturating(_ other: Int) -> Int {
        let (sum, overflow) = self.addingReportingOverflow(other)
        if !overflow {
            return sum
        }
        return other > 0 ? .max : .min
    }
}
