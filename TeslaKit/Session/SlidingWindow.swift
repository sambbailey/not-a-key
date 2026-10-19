import Foundation

/// Anti-replay check for response counters, ported from `window.go`: accepts
/// each counter at most once, tolerating out-of-order delivery up to 32 behind
/// the highest counter seen.
struct SlidingWindow: Sendable {
    static let size: UInt32 = 32

    private var counter: UInt32 = 0
    private var history: UInt64 = 0
    private var used = false

    mutating func accept(_ newCounter: UInt32) -> Bool {
        guard used else {
            used = true
            counter = newCounter
            return true
        }
        if newCounter == counter {
            return false
        }
        if newCounter < counter {
            let age = counter - newCounter
            guard age <= Self.size, history >> (age - 1) & 1 == 0 else {
                return false
            }
            history |= 1 << (age - 1)
            return true
        }
        // Smart shifts yield 0 past 64 bits, matching Go's semantics.
        let shift = newCounter - counter
        history <<= shift
        history |= UInt64(1) << (shift - 1)
        counter = newCounter
        return true
    }
}
