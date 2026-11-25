import ArgumentParser
import Foundation

/**
 The entry point of the tool.

 ```
 osatool decompile   [--strict] [--no-unwrap] [--pass <pass>] <file>
 osatool disassemble [--strict] [--json] <file>
 osatool learn       [--output <file>] <path> ...
 ```

 ArgumentParser reads the command line and runs the subcommand. The exit
 status is 0 for success, 1 when the input could not be processed, and
 64 when the command line is wrong.

 `<file>` is a compiled script, the folder of a script bundle (`.scptd`)
 or of an applet (`.app`), or `-` for standard input.

 ArgumentParser also gives two options of its own: `--version` prints
 the version, and `--generate-completion-script <shell>` prints the
 completion script for bash, fish or zsh. An argument that is a file
 declares `completion: .file()`, or the script offers nothing for it.
 */
@main
struct OSATool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "osatool",
        abstract: "Read compiled AppleScript files (.scpt), also run-only ones.",
        discussion: copyright,
        version: "1.0.0",
        subcommands: [
            Decompile.self,
            Disassemble.self,
            Learn.self,
        ],
    )
}

// MARK: - Copyright

extension ParsableCommand {
    /**
     The years of the copyright line when the year is `year`: "2026" in
     the year the tool was first published, "2026-2027" from the next.
     */
    static func copyrightYears(in year: Int) -> String {
        let first = 2026
        return year > first ? "\(first)-\(year)" : "\(first)"
    }

    /**
     The copyright and the license. Every command has it as the
     `discussion` of its help, or at the end of it.
     */
    static var copyright: String {
        """
        Copyright (c) Melomac \(self.copyrightYears(in: Calendar(identifier: .gregorian).component(.year, from: .now)))

        License GPLv3: GNU General Public License version 3
        <https://codeberg.org/melomac/osatool/src/LICENSE>

        The binary includes third-party code, see NOTICE for copyright notices and license terms
        <https://codeberg.org/melomac/osatool/src/NOTICE>
        """
    }
}
