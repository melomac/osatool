import AST
import Extensions
@testable import Passes
import Terminology
import Testing

@Test func `named passes`() {
    let pass = try? Passes.named("strings")
    #expect(pass?.name == "strings")
    for name in ["naive-strings", "osaminer", "missing"] {
        #expect(throws: ScriptError.self, "removed or unknown pass \(name) accepted") {
            _ = try Passes.named(name)
        }
    }
}
