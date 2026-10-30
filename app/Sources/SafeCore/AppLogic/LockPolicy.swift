import Foundation

// WP3. The decisions of the lock (G4, building plan 4.9) that need no window.
// Only Foundation, so that the file can move to SafeCore and be tested there.

/// When the app locks and what an open window does then.
public enum LockPolicy {
    /// Lock after this many seconds without keyboard, mouse or tablet input on the Mac.
    public static let idleLimit: TimeInterval = 600
    /// How often the idle time is read. Input that comes back between two checks
    /// still locks (IdleLockDecider), at most this much before the 10 minutes.
    public static let checkInterval: TimeInterval = 10

    /// What an open window does when the app locks.
    public enum Response: Equatable {
        case close, cover
    }

    /// An editor without unsaved changes closes; one with unsaved changes covers its
    /// text, so that nothing is discarded without asking.
    public static func editorResponse(hasUnsavedChanges: Bool) -> Response {
        hasUnsavedChanges ? .cover : .close
    }

    /// True if the two byte strings are equal; the time taken depends only on the lengths.
    public static func sameBytes(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count {
            difference |= a[i] ^ b[i]
        }
        return difference == 0
    }
}

/// Decides from the idle time, read every few seconds, whether to lock: once per
/// stretch without input, so that a long absence does not lock again and again.
///
/// The idle time says only when the last input was. A stretch that passed the
/// limit between two checks and ended before the second (the user came back
/// meanwhile, or the check came late because macOS held back the app's timer)
/// is noticed from the check before: if that check found `idle0` seconds and
/// this one, `elapsed` seconds later, finds input since, the stretch lasted at
/// most `idle0 + elapsed - idle`. If that reaches the limit, the app locks now,
/// as soon as it can (finding of review round 4). Input in between that the idle
/// time no longer shows can make it lock up to one check interval early, which
/// errs on the safe side.
public struct IdleLockDecider {
    public let limit: TimeInterval
    private var lockedThisStretch = false
    private var previous: (time: TimeInterval, idle: TimeInterval)?

    public init(limit: TimeInterval = LockPolicy.idleLimit) {
        self.limit = limit
    }

    /// True if the app should lock now, from the idle time alone.
    public mutating func shouldLock(idleSeconds: TimeInterval) -> Bool {
        shouldLock(idleSeconds: idleSeconds, at: nil)
    }

    /// True if the app should lock now; `time` is a clock in seconds that only
    /// goes forward (the system's uptime), nil to judge from the idle time alone.
    public mutating func shouldLock(idleSeconds idle: TimeInterval, at time: TimeInterval?) -> Bool {
        let before = previous
        if let time = time {
            previous = (time, idle)
        }
        if idle >= limit {
            if lockedThisStretch {
                return false
            }
            lockedThisStretch = true
            return true
        }
        let wasLocked = lockedThisStretch
        lockedThisStretch = false
        // a stretch that ended since the last check, which had not locked it yet
        if let time = time, let before = before, !wasLocked, before.idle < limit {
            let elapsed = time - before.time
            if elapsed > 0 && idle < elapsed && before.idle + (elapsed - idle) >= limit {
                return true
            }
        }
        return false
    }
}
