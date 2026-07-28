import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), int(Int), double(Double), bool(Bool)
    case array([JSONValue]), object([String: JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
    public var asString: String? { if case .string(let s) = self { return s }; return nil }
    public var asInt: Int? {
        switch self { case .int(let i): return i; case .double(let d): return Int(d); default: return nil }
    }
    public var asDouble: Double? {
        switch self { case .double(let d): return d; case .int(let i): return Double(i); default: return nil }
    }
    public var asObject: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var asArray: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    /// Strictly a JSON `true`/`false` — a numeric 0/1 is deliberately *not* coerced. The only
    /// caller (`HomeConnection.fetchCurrentUserIsAdmin`) turns a `nil` here into "we don't know
    /// whether this user is an admin," which is safer than guessing an admin flag from a shape
    /// Home Assistant never actually sends.
    public var asBool: Bool? { if case .bool(let b) = self { return b }; return nil }
}
