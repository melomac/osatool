import Foundation

/**
 The stack of the thread that reads a script. Only the part that is
 used takes memory.
 */
package let largeStackSize = 256 << 20

/**
 Runs `body` on a thread with a large stack, waits for it, and returns
 its result.

 The parser, the decompiler and the printer follow the nesting of the
 script with function calls: a list inside a list, an operation inside
 an operation. A script can nest thousands of levels:

 ```
 a & b & c & d & …          3000 operands  →  3000 levels
 ```

 The stack of the thread that asks is often small (512 KB for a
 secondary thread, 8 MB for the main thread), and it would overflow.

 A call made from such a large-stack thread runs `body` directly.

 The new thread takes the priority of the caller (its quality of
 service). A new thread has the default priority, and the caller can
 have a higher one: it would then wait for a thread that the system
 runs after others. The caller waits on a semaphore, which does not
 tell the system which thread to hurry.
 */
package func withLargeStack<T>(_ body: () throws -> T) throws -> T {
    if Thread.current.stackSize >= largeStackSize {
        return try body()
    }
    return try withoutActuallyEscaping(body) { body in
        let work = Work(body)
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            work.result = Result { try work.body!() }
            // The thread must not keep `body` after the caller goes on.
            work.body = nil
            done.signal()
        }
        thread.stackSize = largeStackSize
        thread.qualityOfService = Thread.current.qualityOfService
        thread.start()
        done.wait()
        return try work.result!.get()
    }
}

/**
 What the two threads of `withLargeStack` share. The caller waits for
 the other thread, so the two never use it at the same time.
 */
private final class Work<T>: @unchecked Sendable {
    var body: (() throws -> T)?
    var result: Result<T, any Error>?

    init(_ body: @escaping () throws -> T) {
        self.body = body
    }
}
