import Extensions

/**
 A cursor over a byte array. A read that asks for more bytes than are
 left throws:

 - no byte left: `end of data`;
 - some bytes left, but not enough: `unexpected end of data`, and the
   cursor moves to the end of the data.
 */
struct ByteReader {
    var data: [UInt8]
    var position = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    var remaining: Int {
        self.data.count - self.position
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        if count == 0 {
            return []
        }
        if self.remaining == 0 {
            throw ScriptError("end of data")
        }
        if self.remaining < count {
            self.position = self.data.count
            throw ScriptError("unexpected end of data")
        }
        defer { position += count }
        return Array(self.data[self.position ..< self.position + count])
    }
}
