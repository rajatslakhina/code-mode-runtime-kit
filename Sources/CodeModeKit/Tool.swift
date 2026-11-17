import Foundation

/// How much a tool can change. The tier is part of the tool's type, not of a
/// run's configuration, so no caller can "forget" that `deleteExpense` deletes.
public enum AuthorizationTier: Int, Sendable, Codable, CaseIterable, Comparable, CustomStringConvertible {
    /// Reads app data. Never changes anything.
    case read = 0
    /// Changes app data in a way the user can undo.
    case write = 1
    /// Irreversible, or reaches outside the app. Always needs a human.
    case destructive = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .read: return "read"
        case .write: return "write"
        case .destructive: return "destructive"
        }
    }
}

public struct ToolDescriptor: Sendable, Hashable {
    public let name: String
    public let summary: String
    public let tier: AuthorizationTier
    public let input: SchemaType
    public let output: SchemaType

    public init(name: String, summary: String, tier: AuthorizationTier, input: SchemaType, output: SchemaType) {
        self.name = name
        self.summary = summary
        self.tier = tier
        self.input = input
        self.output = output
    }
}

/// A typed Swift tool a script can call as `await tools.<name>({...})`.
///
/// The descriptor's schema is checked against `Input` when the tool is registered
/// (see `ToolRegistry.register`), so the declaration the model reads and the type
/// the tool decodes cannot silently drift apart.
public protocol CodeModeTool: Sendable {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable
    static var descriptor: ToolDescriptor { get }
    func call(_ input: Input) async throws -> Output
}

/// An error whose message is safe to show to the script (and therefore to the
/// model). Any other error a tool throws reaches the script only as
/// "<tool name> failed", so internal details (paths, SQL, tokens) never leak into a
/// prompt by accident.
public protocol ModelFacingError: Error {
    var modelFacingMessage: String { get }
}

/// Type-erased tool. Input and output cross as JSON bytes only.
public struct AnyCodeModeTool: Sendable {
    public let descriptor: ToolDescriptor
    private let body: @Sendable (Data) async throws -> Data

    init<T: CodeModeTool>(_ tool: T) {
        descriptor = T.descriptor
        body = { data in
            let input = try JSONDecoder().decode(T.Input.self, from: data)
            let output = try await tool.call(input)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(output)
        }
    }

    func invoke(_ arguments: Data) async throws -> Data {
        try await body(arguments)
    }
}
