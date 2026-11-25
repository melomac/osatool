import ArgumentParser
import Extensions
import Foundation
import OSAToolbox

/**
 What one run of the tool works with: its input and output streams, and
 the file where learned terminology is kept.

 The real tool connects them to the process streams and to a file in the
 user's Library. Tests connect them to memory and to a temporary file, so
 a run can be checked without starting a process.
 */
package struct Streams {
    /** Returns all the bytes of standard input. */
    package var readInput: () -> [UInt8]
    package var writeOutput: (String) -> Void
    package var writeError: (String) -> Void
    /** The file `learn` writes and `decompile` reads. `nil`: there is none. */
    package var learnedTerminology: URL?

    package init(
        readInput: @escaping () -> [UInt8], writeOutput: @escaping (String) -> Void, writeError: @escaping (String) -> Void,
        learnedTerminology: URL? = nil,
    ) {
        self.readInput = readInput
        self.writeOutput = writeOutput
        self.writeError = writeError
        self.learnedTerminology = learnedTerminology
    }

    /**
     The streams of the process, and the user's file of learned
     terminology: `~/Library/Application Support/osatool/terminology.json`.
     */
    package static var standard: Streams {
        Streams(
            readInput: { [UInt8](FileHandle.standardInput.readDataToEndOfFile()) },
            writeOutput: { FileHandle.standardOutput.write(Data($0.utf8)) },
            writeError: { FileHandle.standardError.write(Data($0.utf8)) },
            learnedTerminology: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("osatool").appendingPathComponent("terminology.json"),
        )
    }
}

extension Streams {
    /**
     Returns the terms to use: the built-in ones, then the ones saved by
     `learn`. A learned term never replaces a built-in one.

     A saved file that cannot be read is reported and left out.

     - `builtInOnly`: when true, what `learn` saved is not used.
     */
    func terminology(builtInOnly: Bool) throws -> ScriptingTerminology {
        var terminology = try ScriptingTerminology.builtIn()
        guard
            !builtInOnly,
            let url = self.learnedTerminology,
            let data = try? Data(contentsOf: url)
        else {
            return terminology
        }
        do {
            try terminology.add(data)
        } catch {
            self.writeError("\(url.path): \(error.message); learned terminology is not used\n")
        }
        return terminology
    }
}

/** The exit status of the tool. */
enum Status {
    static let success: Int32 = EXIT_SUCCESS
    /** The input could not be read or processed. */
    static let failure: Int32 = EXIT_FAILURE
}

/**
 A subcommand that does its work on the given streams.

 ArgumentParser calls `run()`, which uses the streams of the process. A
 test calls `run(_:)` with streams kept in memory.
 */
package protocol StreamCommand: ParsableCommand {
    /** Runs the command and returns the exit status. */
    func run(_ streams: Streams) -> Int32
}

package extension StreamCommand {
    func run() throws {
        let status = self.run(.standard)
        if status != Status.success {
            throw ExitCode(status)
        }
    }
}

/**
 Where a script bundle (`.scptd`) and an applet (`.app`) keep their
 compiled script, from the folder of the bundle.
 */
let bundleScriptPath = "Contents/Resources/Scripts/main.scpt"

extension Streams {
    /**
     Reads the input: standard input for `-`, a file for any other path.

     A path that names a folder is taken as a bundle, and the script of
     the bundle is read:

     ```
     Demo.scptd  →  Demo.scptd/Contents/Resources/Scripts/main.scpt
     Demo.app    →  Demo.app/Contents/Resources/Scripts/main.scpt
     ```

     - Throws: `ScriptError`, for example
       `open missing.scpt: no such file or directory`.
     */
    func input(at path: String) throws -> [UInt8] {
        if path == "-" {
            return self.readInput()
        }
        var status = stat()
        if stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR {
            return try self.contents(ofFile: (path as NSString).appendingPathComponent(bundleScriptPath))
        }
        return try self.contents(ofFile: path)
    }

    /** Returns all the bytes of a file. */
    private func contents(ofFile path: String) throws -> [UInt8] {
        guard let file = fopen(path, "rb") else {
            throw ScriptError("open \(path): \(errno.systemErrorText)")
        }
        defer { fclose(file) }
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = fread(&buffer, 1, buffer.count, file)
            if count > 0 {
                data.append(contentsOf: buffer[..<count])
            }
            if count < buffer.count {
                if ferror(file) != 0 {
                    throw ScriptError("read \(path): \(errno.systemErrorText)")
                }
                break
            }
        }
        return data
    }
}

extension Int32 {
    /** The system text for an error number, starting with a lowercase letter. */
    var systemErrorText: String {
        let text = String(cString: strerror(self))
        return text.prefix(1).lowercased() + text.dropFirst()
    }
}
