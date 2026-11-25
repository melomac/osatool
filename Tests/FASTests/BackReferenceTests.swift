@testable import FAS
import Testing
import TestSupport

/**
 A script object stores a reference to the script around it, its parent.
 While the file is read, that outer script is not finished yet:

 ```
 script table (being loaded)  ──▶  …  ──▶  script object "main"
        ▲                                         │
        └──────────────── parent ─────────────────┘
 ```

 The parser once registered a block only after its children. It then did
 not know the outer script, reported `RefID mismatch`, and used `nil` for
 the parent. With six script objects it gave up and the file could not be
 read at all.

 Every file in `testdata/backrefs` did that. For each source there is a
 run-only build (`name.scpt`) and a normal one (`name.editable.scpt`).
 */
@Test(arguments: (try? TestData.names(in: "backrefs", suffix: ".scpt")) ?? [])
func `a script object points back to the script around it`(name: String) throws {
    let document = try parse(TestData.bytes("backrefs/\(name).scpt"), options: ParseOptions(strict: true))
    #expect(document.diagnostics.isEmpty)

    // The script table is the last child of the root vector.
    let top = try #require(document.root.vector)
    let table = try #require(top.children.last?.vector)

    // One arrival comes from the root. Every other one is a script object
    // that points back to the table, so the graph has a cycle.
    #expect(arrivals(at: table, from: document.root) >= 2)
}

@Test func `the back reference fixtures are present`() throws {
    let names = try TestData.names(in: "backrefs", suffix: ".scpt")
    let sources = try TestData.names(in: "backrefs", suffix: ".applescript")
    #expect(sources.count == 4)
    for source in sources {
        #expect(names.contains(source), "\(source) has no run-only build")
        #expect(names.contains(source + ".editable"), "\(source) has no editable build")
    }
}

/**
 Counts the references to `target` in the object graph under `root`.
 Each container is entered once, so a cycle does not loop.
 */
private func arrivals(at target: Vector, from root: Value) -> Int {
    var count = 0
    var entered = Visited()
    func visit(_ value: Value) {
        if value.vector === target {
            count += 1
        }
        guard entered.enter(value) else {
            return
        }
        value.children.forEach { visit($0.value) }
    }
    visit(root)
    return count
}
