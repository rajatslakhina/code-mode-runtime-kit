import Foundation

/// The only data shape that crosses the JavaScript <-> Swift boundary.
///
/// Everything a script sends to a tool, and everything a tool sends back, is
/// serialised to JSON text on one side and parsed with explicit limits on the
/// other. No live object references cross the bridge, so a script can never get
/// hold of a Swift object, and a tool can never get hold of a JS closure.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // JSON has no NaN or infinity. JavaScript's JSON.stringify writes them as
            // null, so do the same rather than letting the encoder throw.
            if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Size and nesting limits applied before any JSON is decoded.
public struct JSONLimits: Sendable, Equatable {
    public let maxBytes: Int
    public let maxDepth: Int

    public init(maxBytes: Int = 64 * 1024, maxDepth: Int = 32) {
        self.maxBytes = max(0, maxBytes)
        self.maxDepth = max(1, maxDepth)
    }
}

public enum JSONLimitError: Error, Sendable, Equatable {
    case tooLarge(bytes: Int, limit: Int)
    case tooDeep(limit: Int)
    case malformed
}

extension JSONValue {
    /// Parses JSON text with limits checked *before* decoding.
    ///
    /// The depth check is a linear byte scan rather than a property of the decoded
    /// tree, because the point is to refuse `[[[[...]]]]` bombs before a recursive
    /// decoder ever sees them.
    public static func parse(_ data: Data, limits: JSONLimits) throws -> JSONValue {
        guard data.count <= limits.maxBytes else {
            throw JSONLimitError.tooLarge(bytes: data.count, limit: limits.maxBytes)
        }
        guard nestingDepth(of: data, stopAbove: limits.maxDepth) <= limits.maxDepth else {
            throw JSONLimitError.tooDeep(limit: limits.maxDepth)
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw JSONLimitError.malformed
        }
    }

    public static func parse(_ text: String, limits: JSONLimits) throws -> JSONValue {
        try parse(Data(text.utf8), limits: limits)
    }

    /// Canonical encoding: sorted keys, so two equal values always produce the same
    /// bytes. The trace and the replayer compare arguments by this text.
    public func canonicalText() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Maximum bracket nesting, ignoring brackets inside strings. Stops scanning as
    /// soon as the depth passes `stopAbove`, so a hostile input costs at most one pass.
    static func nestingDepth(of data: Data, stopAbove: Int) -> Int {
        var depth = 0
        var deepest = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth = Saturating.add(depth, 1)
                deepest = max(deepest, depth)
                if deepest > stopAbove { return deepest }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth = max(0, depth - 1)
            default: break
            }
        }
        return deepest
    }
}
