import CaliDomain
import Foundation

/// Deterministic, manually driven clock for tests (domain and, later, CaliCore coordinator tests).
/// Thread-safe so it can be shared with actors under Swift 6 strict concurrency.
public final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Date
    private var mono: TimeInterval

    public init(now: Date, uptime: TimeInterval = 1_000) {
        wall = now
        mono = uptime
    }

    public func now() -> Date { lock.withLock { wall } }
    public func uptime() -> TimeInterval { lock.withLock { mono } }

    /// Normal passage of time while the process runs: wall and monotonic advance together.
    @discardableResult
    public func advance(by seconds: TimeInterval) -> Date {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            mono += seconds
            return wall
        }
    }

    /// Device asleep / app suspended: wall clock advances, Darwin `systemUptime` does not.
    @discardableResult
    public func sleep(for seconds: TimeInterval) -> Date {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            return wall
        }
    }

    /// User or NTP changes the wall clock (positive or negative); monotonic time is unaffected.
    @discardableResult
    public func jumpWallClock(by seconds: TimeInterval) -> Date {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            return wall
        }
    }

    public func set(now: Date) {
        lock.withLock { wall = now }
    }
}
