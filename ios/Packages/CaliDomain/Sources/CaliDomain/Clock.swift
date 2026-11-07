import Foundation

/// Source of time for the coordinator. The reducer itself never reads a clock: it receives `now`
/// explicitly so it stays pure and deterministic.
public protocol Clock: Sendable {
    /// Wall-clock UTC instant. May jump (user changes time, NTP correction).
    func now() -> Date
    /// Monotonic seconds for in-process elapsed measurement. On Darwin `systemUptime` does not
    /// advance while the device sleeps, so only compare readings taken while the process was
    /// continuously executing (docs/03 §5).
    func uptime() -> TimeInterval
}

/// Production clock.
public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
    public func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// Millisecond arithmetic helpers. Durations are stored as integer milliseconds to avoid drift.
public enum TimeMath {
    /// `to - from` in whole milliseconds (rounded).
    public static func ms(from: Date, to: Date) -> Int64 {
        Int64((to.timeIntervalSince(from) * 1000).rounded())
    }

    public static func ms(seconds: Int) -> Int64 { Int64(seconds) * 1000 }

    public static func date(_ base: Date, plusMs ms: Int64) -> Date {
        base.addingTimeInterval(TimeInterval(ms) / 1000)
    }

    public static func date(_ base: Date, plusSeconds s: Int) -> Date {
        base.addingTimeInterval(TimeInterval(s))
    }
}
