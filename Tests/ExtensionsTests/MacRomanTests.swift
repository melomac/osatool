import Extensions
import Testing

@Test func `round trip every byte`() {
    for value in 0 ... 0xff {
        let character = Unicode.Scalar(macRoman: UInt8(value))
        #expect(character.macRomanByte == UInt8(value), "byte \(value)")
    }
}

@Test func decode() {
    #expect(String(macRoman: [0x63, 0x61, 0x66, 0x8e, 0x20, 0xb2]) == "café ≤")
}

@Test func `encode scalar rejects unavailable character`() {
    #expect(("✓" as Unicode.Scalar).macRomanByte == nil)
}
