// swift-tools-version: 6.4
import PackageDescription

// Two products:
//
//   OSAToolbox   the library: decompile and disassemble compiled scripts
//   osatool      the command line tool, made with the library
//
// Targets, from the file format up to the command line tool:
//
//   Extensions      helpers on Swift types, the error and diagnostic types
//   FAS             parser of the compiled script format, reader of a JXA script
//   Bytecode        opcode table and instruction decoder
//   Model           function tables of a script (one file: Sources/Model.swift)
//   Terminology     codes -> words, and the dictionaries linked in as a section
//   AST             syntax tree and source printer
//   Passes          tree transformations
//   Decompilation   bytecode -> syntax tree
//   OSAToolbox      the public face of the library: the only target with `public`
//                   (its folder is Sources/Toolbox)
//   osatool         the executable: the commands, with ArgumentParser
//
// A target is a folder under Sources. A target of one file is that file,
// beside the folders.

// A target of one file sits in the folder of all the others, and must
// say that their folders are not its own.
let sourceFolders = [
    "Extensions", "FAS", "Bytecode", "Terminology", "AST", "Passes", "Decompilation", "Toolbox", "osatool",
]
let testFolders = [
    "ExtensionsTests", "FASTests", "BytecodeTests", "ModelTests", "TerminologyTests", "ASTTests",
    "PassesTests", "DecompilationTests", "ToolboxTests", "testdata",
]

let package = Package(
    name: "osatool",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OSAToolbox", targets: ["OSAToolbox"]),
        .executable(name: "osatool", targets: ["osatool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
    ],
    targets: [
        .target(name: "Extensions"),
        .target(name: "FAS", dependencies: ["Extensions"]),
        .target(name: "Bytecode", dependencies: ["Extensions"]),
        .target(
            name: "Model", dependencies: ["FAS", "Extensions"],
            path: "Sources", exclude: sourceFolders, sources: ["Model.swift"],
        ),
        // The linker copies the terminology into the section (__DATA_CONST,__sref)
        // of every program that holds this target: see Bundled.swift.
        .target(
            name: "Terminology",
            dependencies: ["Extensions"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__DATA_CONST", "-Xlinker", "__sref",
                "-Xlinker", "\(Context.packageDirectory)/Terminology/terminology.sref",
            ])],
        ),
        .target(name: "AST", dependencies: ["Terminology", "Extensions"]),
        .target(name: "Passes", dependencies: ["AST", "Terminology", "Extensions"]),
        .target(
            name: "Decompilation",
            dependencies: ["AST", "Bytecode", "FAS", "Model", "Terminology", "Extensions"],
        ),
        .target(
            name: "OSAToolbox",
            dependencies: ["AST", "Bytecode", "Decompilation", "FAS", "Model", "Passes", "Terminology", "Extensions"],
            path: "Sources/Toolbox",
        ),
        .executableTarget(
            name: "osatool",
            dependencies: [
                "OSAToolbox", "Terminology", "Extensions",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
        ),

        // Tests. `TestSupport` gives every test target access to Tests/testdata.
        .target(name: "TestSupport", path: "Tests", exclude: testFolders, sources: ["TestData.swift"]),
        .testTarget(name: "ExtensionsTests", dependencies: ["Extensions"]),
        .testTarget(name: "FASTests", dependencies: ["FAS", "Extensions", "TestSupport"]),
        .testTarget(name: "BytecodeTests", dependencies: ["Bytecode", "Extensions", "TestSupport"]),
        .testTarget(name: "ModelTests", dependencies: ["Model", "FAS", "Extensions", "TestSupport"]),
        .testTarget(name: "TerminologyTests", dependencies: ["Terminology", "Extensions"]),
        .testTarget(name: "ASTTests", dependencies: ["AST", "Terminology", "Extensions"]),
        .testTarget(name: "PassesTests", dependencies: ["Passes", "AST", "Terminology", "Extensions"]),
        .testTarget(
            name: "DecompilationTests",
            dependencies: ["Decompilation", "AST", "Bytecode", "FAS", "Model", "Terminology", "Extensions"],
        ),
        // The tests of the library and of the commands of the tool.
        .testTarget(
            name: "ToolboxTests",
            dependencies: [
                "OSAToolbox", "osatool", "FAS", "Terminology", "Extensions", "TestSupport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
        ),
    ],
)

// The two libFuzzer targets: one for compiled scripts, one for the
// terminology files that `learn` reads. A target has no `main` of its own
// (libFuzzer brings it), so it links only with `-sanitize=fuzzer`. They are
// added only when the environment variable OSATOOL_FUZZ is set; a normal
// build never sees them. Use Scripts/fuzz.sh, which sets the variable and
// the compiler flags.
if Context.environment["OSATOOL_FUZZ"] != nil {
    // Each target is one file of the folder Fuzz. The rest is data.
    let fuzzData = ["osatool.dict", "terminology.dict", "corpus", "corpus-terminology", "artifacts"]
    package.products.append(.executable(name: "osatool-fuzz", targets: ["osatool-fuzz"]))
    package.targets.append(.executableTarget(
        name: "osatool-fuzz",
        dependencies: ["OSAToolbox"],
        path: "Fuzz",
        exclude: fuzzData + ["TerminologyFuzzTarget.swift"],
        sources: ["FuzzTarget.swift"],
        swiftSettings: [.unsafeFlags(["-parse-as-library"])],
    ))
    package.products.append(.executable(name: "osatool-fuzz-terminology", targets: ["osatool-fuzz-terminology"]))
    package.targets.append(.executableTarget(
        name: "osatool-fuzz-terminology",
        dependencies: ["Terminology", "Extensions"],
        path: "Fuzz",
        exclude: fuzzData + ["FuzzTarget.swift"],
        sources: ["TerminologyFuzzTarget.swift"],
        swiftSettings: [.unsafeFlags(["-parse-as-library"])],
    ))
}
