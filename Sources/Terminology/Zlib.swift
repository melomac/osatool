import Compression
import Extensions
import Foundation

/**
 The largest size a zlib stream may expand to, in bytes. A deflate
 stream can be a thousand times smaller than its data, so a small file
 from an unknown place could ask for all the memory. The terminology
 inside the tool is less than half a megabyte.
 */
package let maximumExpandedSize = 64 * 1024 * 1024

/**
 The zlib format (RFC 1950), made with what Foundation has.

 Foundation compresses and expands the deflate stream. A zlib stream is
 that stream between a header of two bytes and a checksum of four:

 ```
 78 9C | deflate stream … | Adler-32 of the data, high byte first
 ```

 With the header, a program can tell compressed data from text: `78` is
 the letter `x`, and no JSON text starts with it. Any zlib tool reads
 the result.
 */
package extension Data {
    /** True when the data starts with the header of a zlib stream. */
    var isZlibStream: Bool {
        guard self.count >= 6 else {
            return false
        }
        let method = self[self.startIndex]
        let flags = self[self.startIndex + 1]
        // Method 8 is deflate, and the two bytes are a multiple of 31.
        return method & 0x0f == 8 && (UInt16(method) << 8 | UInt16(flags)) % 31 == 0
    }

    /**
     Compresses the data into a zlib stream.

     - Throws: when Foundation cannot compress the data.
     */
    func zlibCompressed() throws -> Data {
        let deflated: Data
        do {
            deflated = try (self as NSData).compressed(using: .zlib) as Data
        } catch {
            throw ScriptError("compress: \(error.localizedDescription)")
        }
        let checksum = self.adler32
        return Data([0x78, 0x9c]) + deflated + Data((0 ..< 4).map { UInt8(truncatingIfNeeded: checksum >> (24 - 8 * $0)) })
    }

    /**
     Expands a zlib stream.

     - `limit`: the largest size of the result, in bytes.
     - Throws: when the data is not a zlib stream, is damaged, expands
       to more than `limit` bytes, or does not have the checksum it
       gives.
     */
    func zlibDecompressed(limit: Int = maximumExpandedSize) throws -> Data {
        guard self.isZlibStream else {
            throw ScriptError("expand: the data is not a zlib stream")
        }
        let inflated = try Data(self.dropFirst(2).dropLast(4)).inflated(limit: limit)
        let stored = self.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard inflated.adler32 == stored else {
            throw ScriptError("expand: the checksum of the data is wrong")
        }
        return inflated
    }

    /**
     Expands a deflate stream piece by piece, so that it can stop as
     soon as the result is larger than `limit` bytes.

     - Throws: when the stream is damaged, ends too early, or expands
       to more than `limit` bytes.
     */
    private func inflated(limit: Int) throws -> Data {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ScriptError("expand: the stream cannot be read")
        }
        defer { compression_stream_destroy(stream) }
        let pieceSize = 64 * 1024
        let piece = UnsafeMutablePointer<UInt8>.allocate(capacity: pieceSize)
        defer { piece.deallocate() }
        var result = Data()
        return try self.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Data in
            guard let start = bytes.bindMemory(to: UInt8.self).baseAddress else {
                throw ScriptError("expand: the data is damaged")
            }
            stream.pointee.src_ptr = start
            stream.pointee.src_size = bytes.count
            while true {
                stream.pointee.dst_ptr = piece
                stream.pointee.dst_size = pieceSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let made = pieceSize - stream.pointee.dst_size
                // No error, no end, and nothing made: the stream stops before its end.
                guard
                    status != COMPRESSION_STATUS_ERROR,
                    status == COMPRESSION_STATUS_END || made > 0
                else {
                    throw ScriptError("expand: the data is damaged")
                }
                result.append(piece, count: made)
                if result.count > limit {
                    throw ScriptError("expand: the data is larger than \(limit) bytes")
                }
                if status == COMPRESSION_STATUS_END {
                    return result
                }
            }
        }
    }

    /** The Adler-32 checksum of the data: two sums of its bytes, each modulo 65521. */
    var adler32: UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in self {
            low = (low + UInt32(byte)) % 65521
            high = (high + low) % 65521
        }
        return high << 16 | low
    }
}
