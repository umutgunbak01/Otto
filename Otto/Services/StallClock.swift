import Foundation

/// Thread-safe "last sign of life" clock shared between a CLI subprocess's
/// stream reader (touches it on every stdout chunk) and its watchdog task
/// (terminates the process when the clock goes stale). `markStalled` records
/// that the watchdog fired, so the turn can throw a timeout error instead of
/// misreporting the kill as a crash.
final class StallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var stalled = false

    func touch() {
        lock.lock()
        last = Date()
        lock.unlock()
    }

    func secondsSinceTouch() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }

    func markStalled() {
        lock.lock()
        stalled = true
        lock.unlock()
    }

    var wasStalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stalled
    }
}
