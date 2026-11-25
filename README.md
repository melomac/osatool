# osatool

`osatool` reads compiled AppleScript files (`.scpt`) and prints them back as
a bytecode listing or as AppleScript source. It also works on run-only
scripts, which Script Editor and `osadecompile` cannot open. It reads
the script of a script bundle (`.scptd`) and of an applet (`.app`), and
it prints the source that a JavaScript for Automation (JXA) script holds.

The project is hosted on [Codeberg](https://codeberg.org/melomac/osatool)
and mirrored on [GitHub](https://github.com/melomac/osatool).

## Thank you, Pepe

This tool stands on the work of **Pepe Berba**.

His [applescript-decompiler](https://github.com/pberba/applescript-decompiler)
is, as far as we know, the first open tool that writes a run-only
AppleScript back as source. Pepe showed that it can be done, and how:

- run the bytecode on a stack of expressions in place of values;
- build `if`, `repeat`, `try` and `tell` blocks back from the jumps;
- take the words of commands from the `.sdef` files of applications;
- put text that was cut into pieces back together, which is the idea
  behind `--pass strings` here.

Every later tool, this one included, started from those ideas. The demo
script of his project is also the first test of this one
(`Tests/testdata/demo.scpt`).

Pepe's project is under the MIT license, copyright (c) 2025 Pepe Berba,
and he kindly agreed to this reuse. Thank you, Pepe: read his
[write-up](https://pberba.github.io/) and use his tool.

His decompiler is itself built on
[applescript-disassembler](https://github.com/Jinmo/applescript-disassembler)
by Jinmo, who first worked out the file format and the instructions.
See [References](#references) for the full line.

## Build and use

Swift 6 and macOS 13 or newer are required.

```sh
git clone https://codeberg.org/melomac/osatool
cd osatool
swift build -c release
.build/release/osatool decompile example.scpt
.build/release/osatool decompile --strict --pass strings example.scpt
.build/release/osatool disassemble example.scpt
.build/release/osatool disassemble --json example.scpt
.build/release/osatool decompile Example.scptd
.build/release/osatool decompile Example.app
.build/release/osatool learn /Applications
```

- Both commands accept `-` to read from standard input.
- Both commands accept a script bundle (`.scptd`) or an applet (`.app`).
  A path that names a folder is taken as one, and the file
  `Contents/Resources/Scripts/main.scpt` inside it is read.
- A JavaScript for Automation (JXA) script has no bytecode. The file
  holds its source text, also when it is run-only. `decompile` prints
  that text as it is, and the options do nothing for it. `disassemble`
  stops with an error that says so.
- The result goes to standard output. Diagnostics go to standard error.
- Without `--strict`, the tool recovers from damaged data when it can.
  With `--strict`, any diagnostic is an error.
- A script that only carries another compiled script (a loader) is
  opened automatically, up to eight loaders one inside the other.
  `decompile --no-unwrap` keeps the outer script.
- A script whose parent was loaded when it was compiled
  (`property parent : load script …`) has the whole library inside it.
  The library is printed as a script object named `scriptObject`.
- A handler whose entry in the file has another name than the handler
  has for itself is printed under the name of the entry, the one that
  calls use, with a diagnostic. A compiler never writes such a file.
- `--pass strings` puts back together text that was cut into pieces
  (`"cu" & "rl"`, `ASCII character 45`, …). It joins only what is proven
  to be text, and it follows a variable only where no other code can
  change it: not a property, not a name of a script around, not a
  variable set by a pattern (`set {a, b} to …`), and, in the run handler
  of the script, not a global that another handler names with `global`
  or reaches as `my a`.
- `osatool --version` prints the version of the tool.

### With make

The Makefile gives one name to each common task:

```sh
make debug     # swift build
make test      # swift test
make lint      # check the format; `make format` writes it
make           # the release build, made by Xcode
make install   # copy it to /usr/local/bin, or to INSTALL_PATH=…
make zip       # /tmp/osatool.zip: the tool, LICENSE and NOTICE
```

The release build is made by `xcodebuild` with the settings of
`osatool.xcconfig`: one binary for x86_64, arm64 and arm64e, for
macOS 13 or newer, with the hardened runtime. It is written to
`/tmp/osatool.dst/usr/local/bin/osatool`.

The signing identity is not in git. Xcode reads it from `local.xcconfig`
when this file is there:

```
CODE_SIGN_IDENTITY = Developer ID Application
CODE_SIGN_STYLE = Manual
DEVELOPMENT_TEAM = …
```

`make brew` installs what the Makefile needs from Homebrew, listed in
the `Brewfile`.

### Completion

The tool writes its own completion script for bash, fish and zsh. The
script completes the commands, the options, the names of the passes, and
file names where a file is expected.

```sh
osatool --generate-completion-script fish
```

With fish, one line is enough. The file holds the command and not what
it prints, so fish asks the tool each time it loads the completions, and
there is nothing to write again when the tool changes:

```sh
echo "osatool --generate-completion-script fish | source" > ~/.config/fish/completions/osatool.fish
```

### Damaged files, and files made to mislead

The tool reads files that anyone could have made. Time and memory
follow the size of the file, and a few things are cut. Each cut is told
on standard error.

| What                                   | Limit                     | What is printed                      |
| -------------------------------------- | ------------------------- | ------------------------------------ |
| instructions in one script             | 1,000,000                 | the rest of the code is not read     |
| blocks one inside the other            | 1,024                     | the inner ones are not opened        |
| operations one inside the other        | 50,000                    | `«expression too deep»`              |
| one expression used again and again    | a few times its real size | `«expression too large»`, or `«value printed above»` for the part that was printed before |
| a list or a record written again       | 4,000,000 values in all   | `«value too large»`                  |
| a text or data written again           | 64 MB in all              | `«long text, 1000000 bytes: "curl -s …"»` |
| diagnostics                            | 100 with the same message | a last line with the number left out |

A limit never hides what comes after it:

- A list, a record or a text is written in full the first time it is
  used, whatever its size. Only what is written again is counted.
- Past a limit, what is small is still written again: a short text, a
  list of a few items, a short statement.
- A statement is never left out. A large part of it that was printed
  before becomes `«value printed above»`, and the rest of the statement
  is written.

So a file cannot use a large value at its start to make the tool leave
out the command that follows it.

`disassemble` has no limit of its own: its listing is about 64 times
the size of the code.

The source of a JXA script is in a property list. A compiler writes the
binary form, but the system also loads a file that holds the XML form
or the old text form, so the tool reads the list as the system does,
with Foundation. A reader for the binary form alone would refuse a file
that the system runs. The size of the file has the same limit as an
AppleScript, 64 MB. Foundation itself refuses more than 512 arrays or
dictionaries one inside the other (since 2021, so on every macOS the
package runs on) and a list that holds itself, and it makes an object
that is used many times only once: a test gives it such lists
(`a hostile property list in a JXA script`). What it says about a
damaged list is not printed, because it quotes the file.

## Terminology

A compiled script stores four-character codes, not words: `'pnam'`, not
`name`. The tool turns codes back into words with dictionaries.

- **Built in:** the AppleScript language and the scripting definitions of
  well-known Apple software.
- **Learned:** `osatool learn <path> ...` reads the definitions of your
  own applications. A path is an application, a folder (searched to any
  depth), or one definition file. Both formats are read: `.sdef`, and the
  older pair `.scriptSuite` + `.scriptTerminology`. A symbolic link to a
  folder is followed when it leads somewhere else, as
  `/Applications/Safari.app` does; a link inside an application is not,
  so that an application cannot send the scan to the rest of the disk.
  When the `Info.plist` of an
  application names its scripting definition, the old script suites it
  still has are left out, as the system does. A file larger than 64 MB
  is not read.

```sh
osatool learn /Applications ~/Applications
```

What is learned is saved in
`~/Library/Application Support/osatool/terminology.json`, and `decompile`
uses it from then on. So does `disassemble`, for the words it writes in
its comments. An application that was learned before is replaced by its
new scan. A learned word never replaces a built-in one;
`--builtin-terminology` makes both commands ignore the saved file. To
forget what was learned, delete the file.

A definition file can be made by anyone, so the rule holds also for a
file that takes the name of something built in. An application named
like a built-in one (`Finder.app`, in any letter case), or a file named
like one the system gives to every application (`Intrinsics.sdef`),
adds words only for the codes that had none: it cannot rename
`do shell script` inside a `tell` block. And `tell application id
"com.apple.finder"` finds the built-in Finder, whatever identifier
another application claims.

### Where a word is printed

The compiler knows the word of an application only where the script
names that application. The tool prints a word only there, so its text
compiles back to the same script:

```applescript
tell application "Finder"
    set a to name of Finder window 1
    tell application "System Events"
        set b to «class brow» 1      -- not a word of System Events
    end tell
end tell
set c to «class brow» 1              -- no application here
```

- The words of the language and of scripting additions are known
  everywhere: Standard Additions, and any `.osax` you let the tool learn.
- A script with a `use` line loads the scripting additions only with
  `use scripting additions`. Without that line the compiler refuses
  their words, so the tool prints the codes:
  `«event sysoexec» "ls"`, not `do shell script "ls"`.
- The application can be named by its name, its path, or its identifier:
  `tell application id "com.apple.finder"`. Named by a variable, it is
  not known, and neither are its words.
- A `tell` block inside another one has the words of its own application
  only. `tell me` and `tell window 1` change nothing, and
  `tell current application` leaves the application.
- The system gives a few words to every application: `properties`,
  `class`, `item`. So `properties of window 1` is printed with the word
  inside a `tell` block for any application, also one the tool does not
  know. Outside, the compiler reads `properties` as `every property`,
  and the tool prints `«class pALL»`.
- An application with script suites and no `.sdef` file, like TextEdit,
  gets more from Cocoa: the standard suite (`document`, `make`), the
  text suite (`paragraph`, `attribute run`) and the types for printing
  (`print settings`).
- `use application "Finder"` makes the words of Finder known in the whole
  script. A word that two such lines bring, and that is not a word of
  the language, is ambiguous for the compiler: it is printed raw outside
  a `tell` block.
- A code with no word in reach is printed raw: `«class brow»`,
  `«constant ****icnv»`, `«event fndrfupd»`, and `«property sdsk»` for
  a property of the target. A raw code compiles everywhere. To get words for an application the tool does not know,
  let it learn the application.

`learn --output file` writes to that file and leaves the saved one as it
is. Two options make the file smaller, and the tool reads every form:

- `--compact`: the JSON on one line, without spaces;
- `--compress`: the file as a zlib stream.

A file written by `learn` can be given to `learn` like an application.
So `osatool learn --compact --compress --output small.sref saved.json`
writes a saved file again in the small form.

The built-in terminology is inside the program, in a section of the
executable file, so the tool is a single file
(see [Built-in terminology](#built-in-terminology)).

## Use it in another program

The package has a library, `OSAToolbox`, beside the tool. It reads a
compiled script and never runs it, so it can be used on files from
anywhere.

```swift
import OSAToolbox

let script = try Data(contentsOf: url)
let result = try decompile(script, options: DecompileOptions(passes: [.strings]))
print(result.source)
for diagnostic in result.diagnostics {
    print(diagnostic)
}
```

| Name                               | What it is                                        |
| ---------------------------------- | ------------------------------------------------- |
| `decompile(_:options:)`            | bytes or `Data` → `DecompileResult`               |
| `disassemble(_:options:)`          | bytes or `Data` → `Disassembly` (`text()`, `json()`) |
| `DecompileOptions`                 | `strict`, `disableEmbeddedUnwrap`, `limits`, `terminology`, `passes` |
| `DecompileResult`                  | `source` (a `String`), `sourceData` (`Data`, UTF-8), `diagnostics`, `embedded`, `language` |
| `Diagnostic`                       | a problem the tool recovered from                 |
| `Limits`                           | upper bounds for a damaged or hostile file        |
| `ScriptingTerminology`             | the dictionaries: built in, saved, or learned     |
| `StrictDecompilationError`         | thrown in strict mode, with the source so far     |

The source comes in two forms. `result.source` is a `String`, to show or
to search. `result.sourceData` is the same text as `Data` in UTF-8, to
write to a file or to hash:

```swift
try result.sourceData.write(to: output)
```

An error says what is wrong in one line: print `error.localizedDescription`.

To add the package, put it in a folder of the other project (a git
submodule, for example) and name that folder:

```swift
dependencies: [
    .package(name: "osatool", path: "osatool"),
],
targets: [
    .target(name: "Client", dependencies: [.product(name: "OSAToolbox", package: "osatool")]),
]
```

In an Xcode project, add the folder as a local package and link
`OSAToolbox`. Two things to know:

- The built-in terminology comes with the library: the linker flag of
  the package also puts the section `(__DATA_CONST,__sref)` in the
  program that uses it. This was tried with `swift build` and with
  `xcodebuild`.
- SwiftPM accepts that flag only for a package given by a path, as
  above, not for a package given by a version.

## Layout

```
Sources/
  Toolbox/         the library OSAToolbox: its public face
  osatool/         the tool: the commands
  Decompilation/   bytecode → syntax tree
  Passes/          tree transformations (strings)
  AST/             syntax tree and source printer
  Terminology/     codes → words; the section reader
  Model.swift      function tables of a script
  Bytecode/        opcode table and instruction decoder
  FAS/             parser of the file format; reader of a JXA script
  Extensions/      helpers on Swift types, MacRoman, the error type
Terminology/       the terminology files, which are data
Tests/             one folder for each target, and testdata/
Fuzz/              the libFuzzer target
Scripts/
```

A target is a folder under `Sources`. A target of one file is that file,
beside the folders (`Sources/Model.swift`, `Tests/TestData.swift`).

```
bytes ─ FAS ─▶ object graph ─ Model ─▶ function tables ─ Bytecode ─▶ instructions
                                                │
                               Decompilation ───┘─▶ AST ─ Passes ─▶ AST ─▶ source text
```

Only `OSAToolbox` has `public` declarations. The targets below it use
the access level `package`: they can change freely, and a program that
uses the library sees one module. `OSAToolbox` holds the two functions
that do the work, `decompile(_:options:)` and `disassemble(_:options:)`.
`osatool` holds the ArgumentParser commands, one file each, and
nothing of ArgumentParser is linked into a program that uses the library.

## Tests

```sh
swift test
```

- Unit tests for every target.
- The 82 compiled fixtures in `Tests/testdata/compiled` must decompile
  to their `.expected.applescript` file. `Scripts/update-expected.sh`
  writes these files again when a change is wanted.
- `Tests/testdata/snapshots` holds the expected listing of every sample.
  The tool must print the same bytes. `Scripts/update-snapshots.sh`
  writes them again when a change is wanted.
- `Tests/testdata/probes` holds more than 400 small scripts, one for
  each form of the language: every operator, block, kind of handler,
  object specifier and common command. Each one is kept compiled, with
  the source the tool must print for it.
  `OSATOOL_APPLE_TOOLS=1 Scripts/update-probes.sh` compiles them again
  and writes that source again.
- `Tests/testdata/fuzz` holds inputs that once made the tool crash or
  print without end.
- `Tests/testdata/styled-text.scpt` holds a text as old versions of
  Script Editor stored it: MacRoman bytes with a style table. No tool
  writes one today, so the file was made by hand from a compiled
  script. `osadecompile` reads it the same way.
- `Tests/testdata/backrefs` holds scripts with script objects. A script
  object points back to the script around it, which the parser once
  could not follow.
- `Tests/testdata/jxa` holds JavaScript for Automation scripts, each
  with its source. They were made with `osacompile -l JavaScript`, and
  `hello-run-only.scpt` with `-x`: it is the same file as `hello.scpt`.
- Real-world samples can be malware and stay outside the repository.
  `OSATOOL_SAMPLES=/path/to/samples swift test` also runs the tool on
  every compiled script found under that folder.
- `OSATOOL_APPLE_TOOLS=1 swift test` also asks Apple's tools to judge
  the source of every fixture and of every probe (see below). These
  tests are not run by default, because `osacompile` can start an
  application to read its dictionary: the probes tell the Finder,
  System Events, Mail, Safari, Terminal and TextEdit. Nothing calls
  `osacompile`
  without this variable, and no script is ever run. Apple's tools get
  the locale `en_US_POSIX` for these tests, so the text of a date does
  not depend on the settings of the Mac.
- [`.github/workflows/test.yml`](https://github.com/melomac/osatool/actions/workflows/test.yml)
  builds and runs `swift test` on GitHub,
  on macOS 26 and on macOS 27 with Xcode 27, with neither variable set.
  Xcode 26 has an older Swift than the package asks for, so on macOS 26
  the workflow installs the Swift of `.swift-version` with swiftly.

### Compared with Apple's tools

The source the tool prints is checked in two ways:

```
script.scpt ── osatool ──▶ source ── osacompile -x ──▶ the same data?
source ── osacompile ──▶ editable script ── osadecompile ──▶ the same text?
```

"The same data" is the whole content of the two compiled files, not
only the instructions: the literals, the names of parameters and
variables, the properties and the script objects. Three things are left
out, because two scripts made from the same source do not share them:
the tree an editable script keeps to print its text, the tree of a
script object made inside a handler, and the content of an alias to an
application.

A run-only script does not keep how its author wrote it. These choices
give the same data, so the tool cannot know them, and it always prints
the first form:

| The tool prints                  | The author may have written        |
| -------------------------------- | ---------------------------------- |
| statements at the top level      | `on run` … `end run` at the end     |
| `if x then` … `end if`           | `if x then statement`               |
| `tell x` … `end tell`            | `tell x to statement`               |
| `a = b`, `a ≠ b`                 | `a is b`, `a is not b`              |
| `item 1 of x`, `item -1 of x`    | `first item of x`, `last item of x` |
| `every item of x`                | `items of x`                        |
| `text of x`                      | `every text of x`                   |
| `name of me`                     | `my name`                           |
| the parentheses Apple prints     | more parentheses                    |
| no empty line between statements | empty lines                         |
| `considering a but ignoring b`   | `ignoring b but considering a`      |
| statements at the top level      | the same inside `using terms from`  |
| `use application "X"` and `property f : application "X"` | `use f : application "X"` |

What is known to differ:

- A date is printed the way Apple's tools print it with the settings of
  the United States: `date "Tuesday, February 3, 1970 at 12:00:00 AM"`.
  The compiler reads the text of a date with the formats of the user's
  settings, so no text means the same date on every Mac. A Mac with
  other settings refuses this one: it does not read another day.
  `osadecompile` prints a date with the settings of the Mac.
- A date before year 1 is printed as raw data, with its 8 bytes last
  byte first: `«data ldt 8091AE02F2FFFFFF»` is 31 December of 1 BC. The
  compiler makes the same date from it. `osadecompile` prints such a
  year with no era (`Friday, December 31, 1`), and the compiler reads
  that text as a day of year 1 AD. A date more than 5.8 million years
  away is printed as raw data too: `osadecompile` prints `date ""`.
- A tab or a line end inside a string is printed as `\t` or `\n`.
  Apple's tools print the character itself, unless Script Editor is set
  to escape them.
- A real number is printed with all the digits it needs to be read back
  as the same number. Apple's tools show twelve.
- Some words that Apple's tools print do not compile back to the code
  they were printed for. The tool prints the raw code there:
  `«class pALL» of x` outside a `tell` block, where `osadecompile`
  prints `properties of x` and the compiler reads that as
  `every property of x`. The same holds for words of old suites, like
  `row` or `USB`, and for the prepositions (`«class abou»`, not `about`).
- One case is left where a printed word does not compile back: a code
  used as a plain value, when its word is the word of a property.
  `set a to «class pnam»` is printed `set a to name`, as `osadecompile`
  prints it, and the compiler reads that as the name of the target. A
  class (`string`), an enumerator (`yes`) and a value given to a command
  (`sort x by name`) compile back.
- Outside the handlers, `using terms from` leaves nothing in the
  compiled script, so the block is not printed there. Its statements
  are, with raw codes for the words that the block gave.
  One case is printed with the block: a handler that answers a command
  of an application, like a rule action of Mail, which compiles only
  inside it.
  Inside a handler the block leaves its application where it starts,
  and nothing where it ends. It is printed from its start to the end of
  the block around it, which compiles to the same script.
- An empty line, or a comment, that is the last line of a block is
  printed as an empty line: the compiler writes code for it.
- A property of the target that has no word is printed
  `«property sdsk»`. `osadecompile` prints `«class sdsk»`, which the
  compiler reads as the class.
- A name that is the first word of a keyword of two words has bars in
  front of the second word: `display dialog |start| with icon 1`,
  `|out| of x`, `repeat with |apart| from 1 to 2`. `osadecompile` prints
  it without bars, and the compiler then reads the keyword.
- A `global` line outside the handlers is printed only where it changes
  the compiled script. Each handler that uses the name also has a
  `global` line of its own.
- `get` is printed only where it changes the code: `f(get item 1 of x)`
  keeps it, `{get item 1 of x}` and a statement `get x` do not.
- The labeled arguments of a call to a handler are printed in the order
  of the language, like Apple's tools do, not in the order of the source.

## Fuzzing

`Scripts/fuzz.sh` builds a [libFuzzer](https://llvm.org/docs/LibFuzzer.html)
target and runs it on inputs that libFuzzer creates from seed files. It
needs a swift.org toolchain (for example one installed with swiftly):
Xcode's Swift has no libFuzzer.

There are two targets:

- `scripts` (the default): the whole library on a compiled script,
  `disassemble` then `decompile`. The seeds are the sample scripts, the
  JXA scripts and the compiled probes.
- `terminology`: the readers of the files `osatool learn` takes, a
  saved terminology file in its three forms, a `.sdef`, a script suite.

```sh
Scripts/fuzz.sh -max_total_time=300      # fuzz scripts for five minutes
Scripts/fuzz.sh terminology -max_total_time=300
Scripts/fuzz.sh -fork=8 -ignore_crashes=1 -ignore_timeouts=1 -ignore_ooms=1
Scripts/fuzz.sh Fuzz/artifacts/crash-…   # run one saved input again
```

`make fuzz` and `make fuzz-terminology` run the two targets for 15
minutes each, or for `FUZZ_SECONDS=…`.

A finding is saved in `Fuzz/artifacts`. Once it is fixed, copy the file
to `Tests/testdata/fuzz` so that `swift test` keeps checking it.

## Built-in terminology

`Terminology` holds the two files that people read
and compare:

- `language.json`: the terms of the AppleScript language, from the
  terminology of the system;
- `applications.json`: the dictionaries of well-known Apple software, in
  the same format as the file `learn` saves.

The terminology of the system still lists words of old suites, such as
`ADB address`, `row` and `USB`, which the compiler refuses or reads as
the name of a variable. `Scripts/compiler-words.py` asks the compiler
about every word a script can use outside a `tell` block, and takes out
the ones that do not compile back to their code: 168 words of the
language, and 3 of Standard Additions.

They are not in the program. The tool writes them as one small file,
which the linker copies into a section of the executable file:

```
language.json ────┐
applications.json ┴─ osatool learn --compact --compress ─▶ terminology.sref
terminology.sref ─── ld -sectcreate __DATA_CONST __sref ─▶ section (__DATA_CONST,__sref)
```

`terminology.sref` is one terminology file, as JSON on one line, as a
zlib stream: about 50 KB for 420 KB of JSON. At its first use the program
reads its own section and expands it. To look at what a build holds:

```sh
otool -s __DATA_CONST __sref .build/release/osatool | head
```

- `Scripts/embed-terminology.sh` makes `terminology.sref` again. Run it
  after a change to one of the two JSON files; a test fails until then.
- `Scripts/update-terminology.sh` makes `applications.json` again from
  the system files listed in `Terminology/sources.txt`, then
  runs the first script. With `OSATOOL_APPLE_TOOLS=1` it also runs
  `Scripts/compiler-words.py`, which needs `osacompile`; without it, run
  that script yourself. Run the tests after it: a new system can change
  the name of a term.

The linker flag is in `Package.swift`. SwiftPM calls it an unsafe flag,
which is fine for a tool that is built from its own package.

## References

Each project is built on the one before it:

- https://github.com/Jinmo/applescript-disassembler by Jinmo (MIT
  license): the file format and the instructions of a compiled script.
- https://github.com/pberba/applescript-decompiler by Pepe Berba (MIT
  license): the first decompiler, built on Jinmo's disassembler.
- https://github.com/ViRb3/applescript-tools by ViRb3: a new version of
  both in Go. This tool started as a Swift port of its version 1.0.2.

## License

`osatool` is licensed under the
[GNU General Public License version 3](LICENSE).

[NOTICE](NOTICE) carries the copyright notices and the license terms of
the work it is built on:

- [applescript-disassembler](https://github.com/Jinmo/applescript-disassembler)
  by Jinmo, under its MIT license;
- [applescript-decompiler](https://github.com/pberba/applescript-decompiler)
  by Pepe Berba, under its MIT license;
- [swift-argument-parser](https://github.com/apple/swift-argument-parser),
  Apache-2.0 with the Runtime Library Exception, which the binary
  includes.
