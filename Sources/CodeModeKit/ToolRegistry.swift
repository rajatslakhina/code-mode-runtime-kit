import Foundation

public enum RegistryError: Error, Sendable, Equatable {
    case invalidName(String)
    case duplicate(String)
    case inputMustBeObject(String)
    case schemaMismatch(tool: String, detail: String)
}

/// The set of tools an app offers to scripts, and the single source of both the
/// model-facing declarations and the JavaScript glue.
public struct ToolRegistry: Sendable {
    private var tools: [String: AnyCodeModeTool] = [:]

    public init() {}

    /// Registers a tool after checking that its name is a safe JavaScript
    /// identifier and that its declared input schema matches its Swift `Input` type.
    ///
    /// The schema check decodes `Input` from two generated examples: one with every
    /// optional field present and one with every optional field omitted. That catches
    /// a field the type requires but the schema does not declare (or declares
    /// optional), and a field declared with the wrong JSON type. It cannot catch a
    /// schema field the Swift type ignores: validation accepts it (it is declared)
    /// and the decoder drops it. Keep `Input` and the schema in one file, and review
    /// them together.
    public mutating func register<T: CodeModeTool>(_ tool: T) throws {
        let descriptor = T.descriptor
        let name = descriptor.name
        guard ToolRegistry.isSafeIdentifier(name) else { throw RegistryError.invalidName(name) }
        guard tools[name] == nil else { throw RegistryError.duplicate(name) }
        guard case .object = descriptor.input else { throw RegistryError.inputMustBeObject(name) }
        for includeOptionals in [true, false] {
            let example = descriptor.input.example(includeOptionals: includeOptionals)
            do {
                let data = Data(example.canonicalText().utf8)
                _ = try JSONDecoder().decode(T.Input.self, from: data)
            } catch {
                let which = includeOptionals ? "with optional fields" : "without optional fields"
                throw RegistryError.schemaMismatch(tool: name, detail: "\(T.Input.self) does not decode the schema's example \(which)")
            }
        }
        tools[name] = AnyCodeModeTool(tool)
    }

    public var descriptors: [ToolDescriptor] {
        tools.values.map(\.descriptor).sorted { $0.name < $1.name }
    }

    func tool(named name: String) -> AnyCodeModeTool? { tools[name] }

    /// The tools a scope may see. Out-of-scope tools are not just refused at call
    /// time, they are absent from the declarations and from the JS `tools` object.
    public func descriptors(in scope: CapabilityScope) -> [ToolDescriptor] {
        descriptors.filter(scope.allows)
    }

    /// TypeScript declarations for the prompt: what the model is told it can call.
    public func typeScriptDeclarations(in scope: CapabilityScope) -> String {
        var lines = ["declare const tools: {"]
        for tool in descriptors(in: scope) {
            let note = scope.needsConfirmation(tool) ? " Pauses for user confirmation." : ""
            lines.append("  /** \(tool.summary) [\(tool.tier)]\(note) */")
            lines.append("  \(tool.name)(input: \(tool.input.typeScript)): Promise<\(tool.output.typeScript)>;")
        }
        lines.append("};")
        return lines.joined(separator: "\n")
    }

    /// JavaScript that turns the single host function into a frozen `tools` object.
    /// Evaluates to a function taking the host function; the host function itself is
    /// never put on the global object, so the only authority a script holds is the
    /// object it is handed.
    func prelude(in scope: CapabilityScope) -> String {
        // Names passed isSafeIdentifier, so they can be embedded in a JS string literal.
        let names = descriptors(in: scope).map { "\"\($0.name)\"" }.joined(separator: ",")
        return """
        (function (host) {
          "use strict";
          const names = [\(names)];
          const tools = Object.create(null);
          for (const name of names) {
            tools[name] = function (input) {
              const payload = JSON.stringify(input === undefined ? {} : input);
              return host(name, payload === undefined ? "null" : payload).then(function (text) {
                return JSON.parse(text);
              });
            };
            Object.freeze(tools[name]);
          }
          return Object.freeze(tools);
        })
        """
    }

    static let reservedWords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
        "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if",
        "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw",
        "true", "try", "typeof", "var", "void", "while", "with", "yield", "let", "static",
        "implements", "interface", "package", "private", "protected", "public", "await", "async",
        "constructor", "prototype", "__proto__", "toString", "valueOf", "hasOwnProperty",
    ]

    /// ASCII letters, digits and `_`, not starting with a digit or `__`, at most 64
    /// characters, and not a reserved word or an Object.prototype member.
    static func isSafeIdentifier(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count), !name.hasPrefix("__"),
              !reservedWords.contains(name), let first = name.utf8.first else { return false }
        func isLetter(_ b: UInt8) -> Bool {
            (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z")) || b == UInt8(ascii: "_")
        }
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        guard isLetter(first) else { return false }
        return name.utf8.allSatisfy { isLetter($0) || isDigit($0) }
    }
}
