import CryptoKit
import Foundation
import OSAToolbox
import Testing

/**
 Runs the tool on compiled scripts kept outside the repository.

 Real-world samples can be malware, so they are not copied into
 `Tests/testdata`. This test reads them where they are:

 ```sh
 OSATOOL_SAMPLES=/path/to/samples swift test
 ```

 The folder is searched to any depth. A file is a compiled script when it
 starts with `FasdUAS `; other files are skipped. Files with the same
 content are run once.

 Every script must disassemble, and must decompile in strict mode: no
 error and no diagnostic. Without the variable the test is skipped.
 */
@Test(.enabled(if: ProcessInfo.processInfo.environment["OSATOOL_SAMPLES"] != nil))
func `every compiled script of the sample folder decompiles`() throws {
    let folder = try #require(ProcessInfo.processInfo.environment["OSATOOL_SAMPLES"])
    let walker = try #require(FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey]))
    let magic = Data("FasdUAS ".utf8)

    var seen = Set<SHA256.Digest>()
    var failures: [String] = []
    for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            continue
        }
        let head = (try? file.read(upToCount: magic.count)) ?? Data()
        try? file.close()
        guard
            head == magic,
            let data = try? Data(contentsOf: url),
            seen.insert(SHA256.hash(data: data)).inserted
        else {
            continue
        }
        let input = [UInt8](data)
        do {
            _ = try disassemble(input)
            _ = try decompile(input, options: DecompileOptions(strict: true))
        } catch let error as StrictDecompilationError {
            failures.append("\(url.path): " + error.diagnostics.map(\.description).joined(separator: "; "))
        } catch {
            failures.append("\(url.path): \(error)")
        }
    }
    #expect(!seen.isEmpty, "no compiled script found in \(folder)")
    #expect(failures.isEmpty, "\(failures.count) of \(seen.count) scripts failed:\n\(failures.joined(separator: "\n"))")
}
