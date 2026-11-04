// A JSON value with JavaScript semantics where the Windows app relies on them: a missing key
// (Swift nil from the subscript) is different from an explicit null, numbers are doubles, and
// "integer" means a finite whole number (Number.isInteger). Used for everything read from
// untrusted sources - the data file, imports and AI answers - before it is validated.
import Foundation

public enum JSONValue: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    public var isPlainObject: Bool {
        if case .object = self { return true }
        return false
    }

    public var isNull: Bool { self == .null }

    public var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let list) = self { return list }
        return nil
    }

    public var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let flag) = self { return flag }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Number.isFinite
    public var finiteNumber: Double? {
        if case .number(let value) = self, value.isFinite { return value }
        return nil
    }

    /// Number.isInteger: a finite whole number (5.0 counts).
    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value, abs(value) < 9.0e15 else { return nil }
        return Int(value)
    }

    public var keys: [String] { objectValue.map { Array($0.keys) } ?? [] }

    /// Whether an object has a key (JS `key in obj` / hasOwnProperty); false for non-objects.
    public func has(_ key: String) -> Bool { objectValue?[key] != nil }

    // MARK: Construction helpers

    public static func from(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    public static func from(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
    public static func from(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
    public static func from(_ values: [Int]) -> JSONValue { .array(values.map { .number(Double($0)) }) }

    // MARK: Parsing and serialization

    public enum ParseError: Error { case invalid }

    public static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ParseError.invalid
        }
        return try JSONValue(any: object)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    init(any: Any) throws {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let text as String:
            self = .string(text)
        case let list as [Any]:
            self = .array(try list.map { try JSONValue(any: $0) })
        case let dict as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (key, value) in dict { result[key] = try JSONValue(any: value) }
            self = .object(result)
        default:
            throw ParseError.invalid
        }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let flag): return NSNumber(value: flag)
        case .number(let value):
            if value.isFinite, value.rounded() == value, abs(value) < 9.0e15 { return NSNumber(value: Int64(value)) }
            return NSNumber(value: value)
        case .string(let text): return text
        case .array(let list): return list.map(\.anyValue)
        case .object(let dict): return dict.mapValues(\.anyValue)
        }
    }

    /// JSON text; `pretty` indents it (as the Windows app does for its data file).
    public func serialized(pretty: Bool = false) -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: anyValue, options: options)) ?? Data("null".utf8)
    }

    public func serializedString(pretty: Bool = false) -> String {
        String(decoding: serialized(pretty: pretty), as: UTF8.self)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
