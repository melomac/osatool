import Extensions
import Foundation
import OSAToolbox
import Testing

/** Calls itself `depth` times, with some bytes on the stack at each level. */
private func descend(_ depth: Int) -> Int {
    var padding = [UInt8](repeating: 1, count: 16)
    padding[depth % 16] = 2
    if depth == 0 {
        return Int(padding[0])
    }
    return descend(depth - 1) + Int(padding[depth % 16]) - 1
}

/**
 A test runs on a thread with a small stack. 100,000 nested calls do
 not fit there, and they do on the large stack.
 */
@Test func `deep recursion runs on the large stack`() throws {
    #expect(Thread.current.stackSize < largeStackSize)
    let result = try withLargeStack { descend(100_000) }
    #expect(result > 0)
}

@Test func `the large stack gives back the result or the error`() throws {
    #expect(try withLargeStack { "done" } == "done")
    #expect(throws: ScriptError.self) {
        try withLargeStack { throw ScriptError("failed") }
    }
    // The work is done on another thread, and a call from there stays there.
    let sizes = try withLargeStack {
        try [Thread.current.stackSize, withLargeStack { Thread.current.stackSize }]
    }
    #expect(sizes == [largeStackSize, largeStackSize])
    let same = try withLargeStack {
        let outer = Thread.current
        return try withLargeStack { Thread.current === outer }
    }
    #expect(same)
}

/**
 The work runs at the priority of the caller. A new thread has the
 default priority: a caller with a higher one would wait for a thread
 that the system runs after others, which Xcode reports as a priority
 inversion, once for each call.

 ```
 caller, a task          thread of the large stack
 utility                 utility
 user-initiated          user-initiated            (was: default)
 ```
 */
@Test func `the large stack runs at the priority of the caller`() async throws {
    let low = try await Task(priority: .utility) {
        try withLargeStack { qos_class_self().rawValue }
    }.value
    #expect(low == QOS_CLASS_UTILITY.rawValue)
    let high = try await Task(priority: .userInitiated) {
        try withLargeStack { qos_class_self().rawValue }
    }.value
    #expect(high == QOS_CLASS_USER_INITIATED.rawValue)
}
