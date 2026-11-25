import Foundation

/**
 Access to the files under `Tests/testdata`.

 The folder is found from the path of this source file, so the tests need
 no resource bundle and can be run from any working directory.

 ```
 Tests/testdata
 ├─ demo.scpt, seccon.scpt     two complete samples
 ├─ compiled/                  <name>.scpt + <name>.expected.applescript
 ├─ oracle/                    <name>.applescript, the source of each fixture
 ├─ snapshots/                 expected listings and sources, see its README
 ├─ backrefs/                  scripts whose script objects point back to their parent
 ├─ probes/                    small scripts, one for each form of the language
 ├─ jxa/                       <name>.scpt + <name>.js, JavaScript for Automation
 └─ fuzz/                      inputs found by the fuzzer, kept as regression tests
 ```
 */
package enum TestData {
    package static let root: URL = .init(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("testdata")

    package static func url(_ relativePath: String) -> URL {
        self.root.appendingPathComponent(relativePath)
    }

    /** Reads a file as bytes. */
    package static func bytes(_ relativePath: String) throws -> [UInt8] {
        try [UInt8](Data(contentsOf: self.url(relativePath)))
    }

    /** Reads a file as UTF-8 text. */
    package static func text(_ relativePath: String) throws -> String {
        try String(decoding: Data(contentsOf: self.url(relativePath)), as: UTF8.self)
    }

    /**
     Returns the names (without extension) of the files in a folder that
     end with `suffix`, sorted.
     */
    package static func names(in folder: String, suffix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: self.url(folder).path)
            .filter { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
            .sorted()
    }

    /** The names of the fixtures in `compiled/`. */
    package static let compiledFixtures: [String] = (try? names(in: "compiled", suffix: ".scpt")) ?? []

    /**
     Makes a compiled JavaScript for Automation script around a property
     list, as the system writes it:

     ```
     "JsOsaDAS1.001.00"  property list  [00 …]  "jscr"  00 01  size  fa de de ad
     ```

     - `padding`: the number of zero bytes after the property list.
       `nil`: what makes the size of the file even.
     */
    package static func javaScript(propertyList: [UInt8], padding: Int? = nil) -> [UInt8] {
        let header = Array("JsOsaDAS1.001.00".utf8)
        let padding = padding ?? (header.count + propertyList.count) % 2
        let size = padding + 12
        return header + propertyList + [UInt8](repeating: 0, count: padding)
            + Array("jscr".utf8) + [0, 1, UInt8(size >> 8), UInt8(size & 0xff), 0xfa, 0xde, 0xde, 0xad]
    }

    /** A property list in one of the forms Foundation writes: binary or XML. */
    package static func propertyList(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> [UInt8] {
        try [UInt8](PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0))
    }
}
