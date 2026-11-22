import Foundation

/// A JSON value that can cross actors. The relay's bodies are small objects; this keeps them
/// typed without `[String: Any]`.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSON(any: any)
    }

    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSON(any: $0) })
        default: self = .null
        }
    }

    /// Foundation objects for `JSONSerialization`; integral numbers stay integers.
    public var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 { return Int64(n) }
            return n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        }
    }

    public func data() -> Data {
        (try? JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    }

    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    /// Whole numbers JSON carries exactly (±2^53); nil for anything else, so a relay's number
    /// can't trap a conversion or the arithmetic on it.
    public var int64: Int64? {
        guard let d = double, d.isFinite, abs(d) <= 9_007_199_254_740_991 else { return nil }
        return Int64(d.rounded(.towardZero))
    }
    public var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    public var isNull: Bool { self == .null }
    public var str: String { string ?? "" }
    public var long: Int64 { int64 ?? 0 }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
}
