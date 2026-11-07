import Foundation

/// JSON coders used for persisted domain values and CON-002 fixtures.
/// Dates are ISO-8601 UTC with millisecond precision on output; input accepts with or without fractions.
public enum DomainJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatter(fractional: true).string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let d = formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text) {
                return d
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO-8601 date: \(text)")
        }
        return decoder
    }

    /// Parses an ISO-8601 timestamp (helper for tests/tools).
    public static func date(_ text: String) -> Date? {
        formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text)
    }

    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        // ISO8601DateFormatter is not Sendable; create per call (cheap enough for persistence/test paths).
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }
}
