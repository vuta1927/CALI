import Foundation
import XCTest

/// Checks payloads against `contracts/entity-payloads.schema.json` without a JSON Schema library: required keys
/// present, no key outside `properties` (closed objects, ADR-030), enum and const respected, `$ref` and `oneOf`
/// followed, nested objects checked the same way.
enum PayloadSchema {
    nonisolated(unsafe) static let defs: [String: Any] = {
        var url = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent("contracts/entity-payloads.schema.json").path), url.path != "/" {
            url.deleteLastPathComponent()
        }
        let data = try! Data(contentsOf: url.appendingPathComponent("contracts/entity-payloads.schema.json"))
        return (try! JSONSerialization.jsonObject(with: data) as! [String: Any])["$defs"] as! [String: Any]
    }()

    static func assertConforms(_ payload: [String: Any], to def: String, file: StaticString = #filePath, line: UInt = #line) {
        check(payload, schema: defs[def] as! [String: Any], path: def, file: file, line: line)
    }

    private static func resolve(_ schema: [String: Any]) -> [String: Any] {
        if let ref = schema["$ref"] as? String, let name = ref.split(separator: "/").last, let target = defs[String(name)] as? [String: Any] { return resolve(target) }
        return schema
    }

    private static func check(_ value: [String: Any], schema raw: [String: Any], path: String, file: StaticString, line: UInt) {
        let schema = resolve(raw)
        if let branches = schema["oneOf"] as? [[String: Any]] {
            let fits = branches.first { branch in
                let props = (branch["properties"] as? [String: Any]) ?? [:]
                let required = (branch["required"] as? [String]) ?? []
                if let kind = (props["kind"] as? [String: Any])?["const"] as? String, value["kind"] as? String != kind { return false }
                return required.allSatisfy { value[$0] != nil } && Set(value.keys).isSubset(of: Set(props.keys))
            }
            XCTAssertNotNil(fits, "\(path): no oneOf branch fits \(value.keys.sorted())", file: file, line: line)
            return
        }
        let properties = (schema["properties"] as? [String: Any]) ?? [:]
        for key in (schema["required"] as? [String]) ?? [] {
            XCTAssertNotNil(value[key], "\(path): missing required \(key)", file: file, line: line)
        }
        for (key, item) in value {
            guard let property = properties[key] as? [String: Any] else {
                XCTFail("\(path): unknown field \(key)", file: file, line: line)
                continue
            }
            if item is NSNull { continue }
            if let allowed = property["enum"] as? [Any], let text = item as? String { XCTAssertTrue(allowed.contains { ($0 as? String) == text }, "\(path).\(key) = \(text)", file: file, line: line) }
            if let nested = item as? [String: Any] { check(nested, schema: property, path: "\(path).\(key)", file: file, line: line) }
        }
    }
}
