import Foundation

/// A deliberately small schema language: enough to describe a tool's input and
/// output to a model, validate what a script actually sends, and print a
/// TypeScript declaration for the prompt. Not JSON Schema; no `oneOf`, no
/// patterns. Every feature added here is a feature the validator must get right.
public indirect enum SchemaType: Sendable, Hashable {
    case string
    case number
    /// A whole number that a Double holds exactly (|n| <= 2^53).
    case integer
    case boolean
    case array(SchemaType)
    case object([SchemaField])
    case optional(SchemaType)
}

public struct SchemaField: Sendable, Hashable {
    public let name: String
    public let type: SchemaType
    public let summary: String

    public init(_ name: String, _ type: SchemaType, _ summary: String = "") {
        self.name = name
        self.type = type
        self.summary = summary
    }
}

/// One problem found while validating a value, with a JSON-path-like location the
/// script (and the model that wrote it) can act on.
public struct SchemaIssue: Sendable, Hashable, CustomStringConvertible {
    public let path: String
    public let problem: String
    public var description: String { "\(path): \(problem)" }
}

extension SchemaType {
    static let maxExactInteger = 9_007_199_254_740_992.0 // 2^53

    /// Validates a value against this schema. Unknown object keys are an error, so
    /// a script cannot smuggle a field the schema does not declare into a tool.
    /// Stops after `limit` issues so the error message stays bounded.
    public func validate(_ value: JSONValue, limit: Int = 8) -> [SchemaIssue] {
        var issues: [SchemaIssue] = []
        collect(value, path: "$", into: &issues, limit: max(1, limit))
        return issues
    }

    private func collect(_ value: JSONValue, path: String, into issues: inout [SchemaIssue], limit: Int) {
        guard issues.count < limit else { return }
        func fail(_ problem: String) { issues.append(SchemaIssue(path: path, problem: problem)) }
        switch (self, value) {
        case (.optional(let wrapped), _):
            if value != .null { wrapped.collect(value, path: path, into: &issues, limit: limit) }
        case (.string, .string), (.boolean, .bool):
            break
        case (.number, .number(let n)):
            if !n.isFinite { fail("expected a finite number") }
        case (.integer, .number(let n)):
            if !(n.isFinite && n.rounded() == n && abs(n) <= SchemaType.maxExactInteger) {
                fail("expected an integer")
            }
        case (.array(let element), .array(let items)):
            for (index, item) in items.enumerated() {
                guard issues.count < limit else { return }
                element.collect(item, path: "\(path)[\(index)]", into: &issues, limit: limit)
            }
        case (.object(let fields), .object(let members)):
            let declared = Set(fields.map(\.name))
            for key in members.keys.sorted() where !declared.contains(key) {
                guard issues.count < limit else { return }
                issues.append(SchemaIssue(path: "\(path).\(key)", problem: "unknown field"))
            }
            for field in fields {
                guard issues.count < limit else { return }
                let child = "\(path).\(field.name)"
                if let member = members[field.name] {
                    field.type.collect(member, path: child, into: &issues, limit: limit)
                } else if case .optional = field.type {
                    continue
                } else {
                    issues.append(SchemaIssue(path: child, problem: "missing required field"))
                }
            }
        default:
            fail("expected \(typeScript)")
        }
    }

    /// A value that satisfies this schema. `includeOptionals: false` omits every
    /// optional object field, which is the other end of what a decoder must accept.
    func example(includeOptionals: Bool) -> JSONValue {
        switch self {
        case .string: return .string("example")
        case .number: return .number(1.5)
        case .integer: return .number(1)
        case .boolean: return .bool(true)
        case .array(let element): return .array([element.example(includeOptionals: includeOptionals)])
        case .optional(let wrapped): return wrapped.example(includeOptionals: includeOptionals)
        case .object(let fields):
            var members: [String: JSONValue] = [:]
            for field in fields {
                if case .optional = field.type, !includeOptionals { continue }
                members[field.name] = field.type.example(includeOptionals: includeOptionals)
            }
            return .object(members)
        }
    }

    /// The TypeScript spelling the model sees in its tool declarations.
    public var typeScript: String {
        switch self {
        case .string: return "string"
        case .number, .integer: return "number"
        case .boolean: return "boolean"
        case .array(let element): return "Array<\(element.typeScript)>"
        case .optional(let wrapped): return "\(wrapped.typeScript) | null"
        case .object(let fields):
            let members = fields.map { field -> String in
                if case .optional(let wrapped) = field.type {
                    return "\(field.name)?: \(wrapped.typeScript)"
                }
                return "\(field.name): \(field.type.typeScript)"
            }
            return "{ " + members.joined(separator: "; ") + " }"
        }
    }
}
