import Foundation

// CON-008 (docs/18 §5, ADR-045/066/067): the criteria config that drives the extra fields of the set
// result form (P6), plus the pure rules for the values entered. Primary measures (hold, reps, load,
// distance, duration) are NOT criteria: they follow the exercise measurement type (ADR-060).

/// Display unit for load (ADR-046). Storage is always kg; lb is a display and entry convenience.
public enum WeightUnit: String, Codable, Sendable, CaseIterable {
    case kg, lb

    static let poundsPerKilogram = Decimal(string: "2.20462262")!

    public var label: String { rawValue }

    /// kg → shown value (lb rounded to 0.1, kg unchanged).
    public func display(kg: Decimal) -> Decimal {
        guard self == .lb else { return kg }
        return Self.round(kg * Self.poundsPerKilogram, digits: 1)
    }

    /// Typed value → kg to store (at most 2 decimals, ADR-062). Entering lb is the only place a conversion
    /// rounds; a typed kg value is kept exactly.
    public func kg(fromDisplayed value: Decimal) -> Decimal {
        guard self == .lb else { return value }
        return Self.round(value / Self.poundsPerKilogram, digits: DomainLimits.loadKgFractionDigits)
    }

    private static func round(_ value: Decimal, digits: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, digits, .plain)
        return result
    }
}

extension ExerciseType {
    /// `appliesTo.disciplines` value of the exercise, derived from its type (docs/18 §4).
    public var criteriaDiscipline: String {
        switch self {
        case .load: "gym"
        case .distance, .duration: "running"
        default: "calisthenics"
        }
    }
}

public struct CriterionOption: Codable, Hashable, Sendable {
    public var v: String
    public var label: String
    public var hint: String?

    public init(v: String, label: String, hint: String? = nil) {
        self.v = v
        self.label = label
        self.hint = hint
    }
}

public struct CriteriaAppliesTo: Codable, Hashable, Sendable {
    public var disciplines: [String]
    public var measurementTypes: [MeasurementType]?
    public var exerciseIds: [UUID]?

    public init(disciplines: [String], measurementTypes: [MeasurementType]? = nil, exerciseIds: [UUID]? = nil) {
        self.disciplines = disciplines
        self.measurementTypes = measurementTypes
        self.exerciseIds = exerciseIds
    }

    public func matches(exerciseId: UUID, type: ExerciseType) -> Bool {
        guard disciplines.contains("*") || disciplines.contains(type.criteriaDiscipline) else { return false }
        if let measurementTypes, !measurementTypes.contains(type.measurementType) { return false }
        if let exerciseIds, !exerciseIds.contains(exerciseId) { return false }
        return true
    }
}

/// `type` is an open string: a type this build does not know is skipped, never an error (docs/18 §5.2).
public struct Criterion: Codable, Hashable, Sendable, Identifiable {
    public static let knownTypes: Set<String> = ["number", "choice", "scale", "chips", "toggle"]
    /// Ids that only control display of a column (ADR-045); their values never go into the `criteria` map.
    public static let columnBackedIds: Set<String> = ["rpe", "pain"]
    static let reservedKeys: Set<String> = ["rpe", "pain", "holdSec", "reps", "loadKg"]

    public var id: String
    public var type: String
    public var label: String
    public var hint: String?
    public var icon: String?
    public var appliesTo: CriteriaAppliesTo
    public var options: [CriterionOption]?
    public var min: Decimal?
    public var max: Decimal?
    public var step: Decimal?
    public var unit: String?
    public var prefill: String?
    public var splitsTrend: Bool?
    public var required: Bool?
    public var enabled: Bool

    public init(id: String, type: String, label: String, hint: String? = nil, icon: String? = nil, appliesTo: CriteriaAppliesTo,
                min: Decimal? = nil, max: Decimal? = nil, step: Decimal? = nil, unit: String? = nil,
                prefill: String? = nil, splitsTrend: Bool? = nil, required: Bool? = nil, options: [CriterionOption]? = nil,
                enabled: Bool = true) {
        self.id = id
        self.type = type
        self.label = label
        self.hint = hint
        self.icon = icon
        self.appliesTo = appliesTo
        self.options = options
        self.min = min
        self.max = max
        self.step = step
        self.unit = unit
        self.prefill = prefill
        self.splitsTrend = splitsTrend
        self.required = required
        self.enabled = enabled
    }

    public var isKnown: Bool { Self.knownTypes.contains(type) }
    public var isColumnBacked: Bool { Self.columnBackedIds.contains(id) }
    public var prefillsFromPreviousSet: Bool { prefill == "previousSet" }

    /// Structural check of one criterion (choice/chips need options, scale needs min ≤ max).
    var isWellFormed: Bool {
        switch type {
        case "choice", "chips": return !(options ?? []).isEmpty && (options?.count ?? 0) <= 10
        case "scale": if let min, let max { return min <= max } else { return false }
        default: return true
        }
    }
}

/// `criteria_values` entry: a token, a number, a boolean or a list of tokens. No free text (ADR-067).
public enum CriteriaValue: Hashable, Sendable, Codable {
    case token(String)
    case number(Decimal)
    case bool(Bool)
    case tokens([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let s = try? c.decode(String.self) { self = .token(s); return }
        if let t = try? c.decode([String].self) { self = .tokens(t); return }
        self = .number(try c.decode(Decimal.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .token(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .tokens(let t): try c.encode(t)
        }
    }
}

/// A published, immutable criteria config version (`GET /v1/criteria-config`, db/008).
public struct CriteriaConfig: Codable, Hashable, Sendable {
    public var version: Int
    public var publishedAt: Date?
    public var supportedTypes: [String]
    public var criteria: [Criterion]

    public init(version: Int, publishedAt: Date? = nil, supportedTypes: [String], criteria: [Criterion]) {
        self.version = version
        self.publishedAt = publishedAt
        self.supportedTypes = supportedTypes
        self.criteria = criteria
    }

    /// Criteria to render for an exercise, in config order: enabled, known type, well formed, matching.
    public func applicable(exerciseId: UUID, type: ExerciseType) -> [Criterion] {
        criteria.filter { $0.enabled && $0.isKnown && $0.isWellFormed && $0.appliesTo.matches(exerciseId: exerciseId, type: type) }
    }

    public func criterion(_ id: String) -> Criterion? { criteria.first { $0.id == id } }

    /// Config version 1 = `db/008` seed = `fixtures/criteria_config.json`: the config bundled in the app,
    /// used on first launch and whenever a cached config cannot be read (docs/18 §5.3).
    public static let bundled = CriteriaConfig(
        version: 1, publishedAt: nil, supportedTypes: ["number", "choice", "scale", "chips", "toggle"],
        criteria: [
            Criterion(id: "technique", type: "choice", label: "Kỹ thuật (tự đánh giá)", icon: "star",
                      appliesTo: CriteriaAppliesTo(disciplines: ["*"]), required: false,
                      options: [CriterionOption(v: "poor", label: "Chưa ổn", hint: "Form vỡ"),
                                CriterionOption(v: "ok", label: "Ổn", hint: "Vài lỗi nhỏ"),
                                CriterionOption(v: "good", label: "Chuẩn", hint: "Giữ form tốt")]),
            Criterion(id: "rpe", type: "scale", label: "Mức gắng sức (RPE)", hint: "10 = không thể thêm lần nào.", icon: "chart",
                      appliesTo: CriteriaAppliesTo(disciplines: ["gym"]), min: 6, max: 10, step: 1, required: false),
            Criterion(id: "condition", type: "chips", label: "Điều kiện tập", icon: "swap",
                      appliesTo: CriteriaAppliesTo(disciplines: ["calisthenics"]), prefill: "previousSet", splitsTrend: true, required: false,
                      options: [CriterionOption(v: "same", label: "Như set trước"), CriterionOption(v: "assist", label: "Có trợ lực"),
                                CriterionOption(v: "variant", label: "Đổi biến thể"), CriterionOption(v: "equip", label: "Đổi dụng cụ")]),
            Criterion(id: "equipment", type: "chips", label: "Dụng cụ", icon: "barbell",
                      appliesTo: CriteriaAppliesTo(disciplines: ["gym"]), prefill: "previousSet", splitsTrend: true, required: false,
                      options: [CriterionOption(v: "barbell", label: "Tạ đòn"), CriterionOption(v: "dumbbell", label: "Tạ đơn"),
                                CriterionOption(v: "machine", label: "Máy"), CriterionOption(v: "smith", label: "Smith")]),
            Criterion(id: "pain", type: "toggle", label: "Đau bất thường trong set",
                      hint: "Chỉ ghi lại để bạn xem lại. Ứng dụng không chẩn đoán.", icon: "alert",
                      appliesTo: CriteriaAppliesTo(disciplines: ["*"]), required: false),
        ])

    /// Cached config JSON → config, or the bundled one when the data is missing, unreadable, version < 1,
    /// or older than the bundled version (never go backwards).
    public static func resolve(cached: Data?) -> CriteriaConfig {
        guard let cached, let config = try? DomainJSON.makeDecoder().decode(CriteriaConfig.self, from: cached),
              config.version >= bundled.version else { return bundled }
        return config
    }
}

public enum CriteriaValidation {
    public static let maxKeys = 20
    public static let maxBytes = 8192

    /// Checks the `criteria` map of a set result against the config version it was entered with
    /// (ADR-067): keys, kinds, options, ranges and size. `config == nil` checks only the structural limits.
    public static func validate(_ values: [String: CriteriaValue], config: CriteriaConfig?) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func bad(_ field: String, _ reason: ValidationIssue.Reason, _ detail: String) {
            issues.append(ValidationIssue(field: "criteria.\(field)", reason: reason, detail: detail))
        }
        if values.count > maxKeys { bad("*", .outOfRange, "\(values.count) keys > \(maxKeys)") }
        if let data = try? DomainJSON.makeEncoder().encode(values), data.count > maxBytes {
            bad("*", .outOfRange, "\(data.count) bytes > \(maxBytes)")
        }
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            if Criterion.reservedKeys.contains(key) { bad(key, .notAllowed, "column-backed or primary measure"); continue }
            if case .tokens(let list) = value, list.count > 10 || Set(list).count != list.count { bad(key, .outOfRange, "up to 10 unique tokens") }
            guard let config else { continue }
            guard let criterion = config.criterion(key), criterion.enabled, criterion.isKnown, !criterion.isColumnBacked else {
                bad(key, .notAllowed, "not an enabled criterion of version \(config.version)")
                continue
            }
            let tokens = Set((criterion.options ?? []).map(\.v))
            switch (criterion.type, value) {
            case ("choice", .token(let v)): if !tokens.contains(v) { bad(key, .notAllowed, "unknown option") }
            case ("chips", .tokens(let list)): if !Set(list).isSubset(of: tokens) { bad(key, .notAllowed, "unknown option") }
            case ("chips", .token(let v)): if !tokens.contains(v) { bad(key, .notAllowed, "unknown option") }
            case ("scale", .number(let n)), ("number", .number(let n)):
                if let lo = criterion.min, n < lo { bad(key, .outOfRange, "\(n) < \(lo)") }
                if let hi = criterion.max, n > hi { bad(key, .outOfRange, "\(n) > \(hi)") }
            case ("toggle", .bool): break
            default: bad(key, .inconsistent, "wrong kind for \(criterion.type)")
            }
        }
        return issues
    }
}
