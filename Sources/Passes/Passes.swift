import AST
import Extensions

/**
 A transformation of the syntax tree, applied after decompilation.

 A pass may change the tree in place and return the same `Script`.
 */
package protocol Pass {
    var name: String { get }
    func rewrite(_ script: Script) -> (Script, [Diagnostic])
}

/**
 Returns the pass with the given name. The only pass is `strings`.

 - Throws: when no pass has this name.
 */
package func named(_ name: String) throws -> any Pass {
    switch name {
    case "strings":
        Strings()
    default:
        throw ScriptError("unknown pass \(name.quoted)")
    }
}
