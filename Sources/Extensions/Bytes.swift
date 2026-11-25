package extension Sequence<UInt8> {
    /**
     True when every byte is a printable ASCII character (`0x20` to
     `0x7e`). An empty sequence is printable.
     */
    var isPrintableASCII: Bool {
        allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
    }
}

package extension String {
    /**
     Decodes UTF-16 big-endian text: two bytes for each code unit, the
     high byte first.

     A damaged pair of code units gives U+FFFD. When the number of bytes
     is odd, the last byte is ignored.
     */
    init(utf16BigEndian bytes: [UInt8]) {
        var units = [UInt16](repeating: 0, count: bytes.count / 2)
        for index in units.indices {
            units[index] = UInt16(bytes[index * 2]) << 8 | UInt16(bytes[index * 2 + 1])
        }
        self.init(decoding: units, as: UTF16.self)
    }
}
