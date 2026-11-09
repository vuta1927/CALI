import CaliDomain
import Foundation
import GRDB

extension DatabaseWriter {
    /// `BEGIN IMMEDIATE … COMMIT`; any thrown error rolls back every write of the body.
    func immediateTransaction<T>(_ body: (Database) throws -> T) throws -> T {
        try writeWithoutTransaction { db in
            var result: T?
            try db.inTransaction(.immediate) {
                result = try body(db)
                return .commit
            }
            return result!
        }
    }
}

/// JSON columns use the domain encoder (sorted keys, ISO-8601 dates) so stored documents are stable.
enum DBJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try DomainJSON.makeEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try DomainJSON.makeDecoder().decode(type, from: Data(text.utf8))
    }
}

extension DBText {
    static func date(_ day: LocalDate) -> String { day.description }

    static func uuid(_ text: String) -> UUID? { UUID(uuidString: text) }
}
