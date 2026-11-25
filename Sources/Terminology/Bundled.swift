import Foundation
import MachO

/**
 The terminology built into the program.

 It is not Swift code and not a resource file: the linker copies the
 file `terminology.sref` into a section of the program, and the
 program reads its own section. The files are in the folder
 `Terminology`, at the top of the package:

 ```
 language.json       the words of the language ─┐
 applications.json   the words of applications ─┴─ osatool learn --compact --compress
                                                            │
 terminology.sref   one terminology store, as a zlib stream  ◀─┘
        │
        └─ ld -sectcreate __DATA_CONST __sref terminology.sref ──▶ section (__DATA_CONST,__sref)
 ```

 The two JSON files are the ones to read and to compare. They are not
 in the program. `Scripts/embed-terminology.sh` makes `terminology.sref`
 from them again, and a test says when it was forgotten. `sources.txt`
 lists the system files `applications.json` is made from;
 `Scripts/update-terminology.sh` makes it again.

 The linker flag is in `Package.swift`. It is used for every program
 that holds this target: the tool, and the test bundles.
 */
package enum BundledTerminology {
    /**
     The segment of the section. `__DATA_CONST` holds the data of a program
     that does not change: the system makes it read-only when the program
     starts.
     */
    package static let segment = "__DATA_CONST"
    /** The name of the section. */
    package static let section = "__sref"

    /**
     The content of the section: a terminology store, as a zlib stream.
     It is `nil` in a program that was linked without the section.
     */
    package static let store: Data? = Data(machOSection: section, segment: segment)
}

package extension Data {
    /**
     Copies a section of a program or library that is loaded in memory.

     - `image`: the start of the program or library. The default is the
       one that holds the code of the caller.
     - Returns: `nil` when it has no such section.
     */
    init?(machOSection section: String, segment: String, image: UnsafeRawPointer = #dsohandle) {
        var size: UInt = 0
        guard let start = getsectiondata(image.assumingMemoryBound(to: mach_header_64.self), segment, section, &size) else {
            return nil
        }
        self.init(bytes: start, count: Int(size))
    }
}
