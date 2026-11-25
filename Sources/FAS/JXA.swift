import Extensions
import Foundation

/** The first bytes of a compiled JavaScript for Automation (JXA) script. */
let javaScriptMagic = Array("JsOsaDAS".utf8)

/** The last bytes of a compiled script of any language. */
let trailerMagic: [UInt8] = [0xfa, 0xde, 0xde, 0xad]

/**
 True when the data is a compiled JXA script: it starts with `JsOsaDAS`,
 after an optional `#!` line.
 */
package func isJavaScript(_ input: [UInt8]) -> Bool {
    guard let start = endOfHashbang(input) else {
        return false
    }
    return input[start...].starts(with: javaScriptMagic)
}

/**
 Returns the source text of a compiled JXA script.

 Such a file has no bytecode. It holds the source text in a property
 list, and a run-only file holds it too: `osacompile -x` writes the same
 bytes as `osacompile`.

 ```
 [#!… line]      optional, skipped
 "JsOsaDAS"      magic
 "1.001.00"      version
 property list   { script = "the source text"; }
 [00 …]          padding: the size of the file is even
 "jscr"          the scripting component that reads the file
 00 01           version of the trailer
 00 0d           size of the trailer, with the padding
 fa de de ad     magic of the trailer
 ```

 The size of the trailer says where the property list ends. The source
 is the text under the key `script`. The other keys are not read.

 The system reads the property list with Foundation, and so does this
 function. A compiler writes the binary form, but the system also loads
 a file with the XML form or the old text form. A reader made for the
 binary form alone would refuse a file that the system runs.

 Foundation can be given a hostile property list. This was tried on
 macOS 27:

 - it refuses more than 512 arrays or dictionaries one inside the other,
   in the three forms, so the stack does not overflow;
 - an object of the binary form that is used many times is made once,
   so memory follows the size of the file;
 - it refuses an object that holds itself, and a size that goes past the
   end of the data.

 The limit on nesting is in the system since 2021 (iOS 14.4), so every
 macOS the package runs on has it. The size of the file has the limit
 `maxInputBytes`.

 The tool reads more files than the system loads: the version, the
 component and the version of the trailer are not checked, and the size
 of the file can be odd. The text is what the file holds in any case.

 - Throws: `ScriptError` when the data is not a JXA script, is over the
   limit, has no trailer, or has no source text in a property list.
 */
package func javaScriptSource(_ input: [UInt8], limits: Limits = Limits()) throws -> String {
    let maximum = limits.maxInputBytes > 0 ? limits.maxInputBytes : Limits.defaults().maxInputBytes
    if input.count > maximum {
        throw ScriptError("JXA stream exceeds \(maximum)-byte limit")
    }
    guard let start = endOfHashbang(input) else {
        throw ScriptError("unterminated hashbang")
    }
    // Offsets are counted from the first byte after the `#!` line.
    let data = input[start...]
    let magic = Array(data.prefix(javaScriptMagic.count))
    if magic != javaScriptMagic {
        throw ScriptError("invalid JXA magic \(magic.quoted)")
    }

    // The magic and the version at the start, the fixed part of the trailer at the end.
    let headerSize = 16
    let trailerSize = 12
    if data.count < headerSize + trailerSize {
        throw ScriptError("read JXA trailer at 0x\(data.count.hex): unexpected end of data")
    }
    let found = Array(data.suffix(trailerMagic.count))
    if found != trailerMagic {
        throw ScriptError("invalid JXA trailer magic \(found.quoted) at 0x\((data.count - trailerMagic.count).hex)")
    }
    let sizeOffset = data.endIndex - 6
    let size = Int(data[sizeOffset]) << 8 | Int(data[sizeOffset + 1])
    if size < trailerSize || size > data.count - headerSize {
        throw ScriptError("invalid JXA trailer size \(size) at 0x\((data.count - 6).hex)")
    }
    let propertyList = data[(data.startIndex + headerSize) ..< (data.endIndex - size)]

    // Foundation says what is wrong with words of the file: its text is not printed.
    // `options: []` asks for values that cannot change: an object used many times is made once.
    guard let value = try? PropertyListSerialization.propertyList(from: Data(propertyList), options: [], format: nil) else {
        throw ScriptError("read JXA property list at 0x\(headerSize.hex): damaged property list")
    }
    // A dictionary of the binary form can have keys that are not text.
    guard let dictionary = value as? NSDictionary else {
        throw ScriptError("JXA property list is not a dictionary")
    }
    guard let script = dictionary["script"] else {
        throw ScriptError("JXA property list has no \"script\" key")
    }
    guard let source = script as? String else {
        throw ScriptError("JXA \"script\" value is not text")
    }
    return source
}
