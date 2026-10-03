import Foundation

/// Type-preserving JSON value. Unlike `JSONSerialization`, `true` stays a bool and `1` stays an int on round-trip.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func prettyData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// Configuration-specific key order; unknown fields remain intact and sort last.
    func configurationData() throws -> Data {
        let orders = [
            "root": ["providers"],
            "provider": ["api", "apiKey", "baseUrl", "models"],
            "model": ["id", "name", "api", "baseUrl", "reasoning", "input", "thinkingLevelMap",
                      "contextWindow", "maxTokens", "cost", "compat"],
            "thinkingLevelMap": ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
            "cost": ["input", "output", "cacheRead", "cacheWrite", "tiers"],
            "tier": ["inputTokensAbove", "input", "output", "cacheRead", "cacheWrite"],
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        func render(_ value: JSONValue, depth: Int, context: String) throws -> String {
            let indent = String(repeating: "  ", count: depth)
            let childIndent = indent + "  "
            switch value {
            case .object(let object):
                if object.isEmpty { return "{}" }
                let order = orders[context] ?? []
                let keys = order.filter { object[$0] != nil }
                    + object.keys.filter { !order.contains($0) }.sorted()
                let lines = try keys.map { key in
                    let childContext: String
                    switch (context, key) {
                    case ("root", "providers"): childContext = "providers"
                    case ("providers", _): childContext = "provider"
                    case ("provider", "models"): childContext = "model"
                    case ("model", "thinkingLevelMap"), ("model", "cost"): childContext = key
                    case ("cost", "tiers"): childContext = "tier"
                    default: childContext = ""
                    }
                    let quotedKey = String(decoding: try encoder.encode(key), as: UTF8.self)
                    let child = try render(object[key]!, depth: depth + 1, context: childContext)
                    return childIndent + quotedKey + ": " + child
                }
                return "{\n" + lines.joined(separator: ",\n") + "\n" + indent + "}"
            case .array(let items):
                if items.isEmpty { return "[]" }
                let lines = try items.map {
                    childIndent + (try render($0, depth: depth + 1, context: context))
                }
                return "[\n" + lines.joined(separator: ",\n") + "\n" + indent + "]"
            default:
                return String(decoding: try encoder.encode(value), as: UTF8.self)
            }
        }

        return Data((try render(self, depth: 0, context: "root") + "\n").utf8)
    }
}
