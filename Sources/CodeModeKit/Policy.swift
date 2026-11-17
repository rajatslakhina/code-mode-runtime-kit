import Foundation

/// What one run may touch. Built per run, so the same registry can serve a
/// read-only "summarise my month" request and a "clean up duplicates" request
/// with different authority.
public struct CapabilityScope: Sendable, Equatable {
    /// Tool names this run may see. `nil` means every registered tool.
    public var allowedTools: Set<String>?
    /// Highest tier this run may call at all.
    public var maxTier: AuthorizationTier
    /// Tiers at or above this one pause for confirmation. `.destructive` is the
    /// highest tier, so destructive tools always pause whatever this says: the
    /// policy can be made stricter, never looser.
    public var confirmAtOrAbove: AuthorizationTier

    public init(allowedTools: Set<String>? = nil, maxTier: AuthorizationTier = .destructive, confirmAtOrAbove: AuthorizationTier = .destructive) {
        self.allowedTools = allowedTools
        self.maxTier = maxTier
        self.confirmAtOrAbove = confirmAtOrAbove
    }

    public static let readOnly = CapabilityScope(maxTier: .read)

    public func allows(_ tool: ToolDescriptor) -> Bool {
        guard tool.tier <= maxTier else { return false }
        if let allowedTools { return allowedTools.contains(tool.name) }
        return true
    }

    public func needsConfirmation(_ tool: ToolDescriptor) -> Bool {
        tool.tier >= confirmAtOrAbove
    }
}

/// Resource limits for one run. Every value is clamped to a sane range on init,
/// so a zero or negative value from a settings screen cannot disable a limit.
public struct ExecutionBudget: Sendable, Equatable {
    /// Tool-call attempts, including refused ones. Counting refusals too means a
    /// script cannot spin on an unknown tool name for free.
    public let maxToolCalls: Int
    /// Wall-clock deadline for the whole run.
    public let deadline: Duration
    /// Size of the script source.
    public let maxScriptBytes: Int
    /// Limits on each tool call's arguments.
    public let argumentLimits: JSONLimits
    /// Limits on each tool result and on the script's final value.
    public let resultLimits: JSONLimits

    public init(
        maxToolCalls: Int = 32,
        deadline: Duration = .seconds(5),
        maxScriptBytes: Int = 16 * 1024,
        argumentLimits: JSONLimits = JSONLimits(maxBytes: 8 * 1024, maxDepth: 16),
        resultLimits: JSONLimits = JSONLimits(maxBytes: 64 * 1024, maxDepth: 32)
    ) {
        self.maxToolCalls = min(max(0, maxToolCalls), 10_000)
        let floor = Duration.milliseconds(1)
        let ceiling = Duration.seconds(600)
        self.deadline = min(max(deadline, floor), ceiling)
        self.maxScriptBytes = max(0, maxScriptBytes)
        self.argumentLimits = argumentLimits
        self.resultLimits = resultLimits
    }

    /// Host calls the engine accepts before it stops spawning work for them at all.
    /// The bridge refuses everything past `maxToolCalls`; this second, cheaper limit
    /// sits on the JavaScript side so a synchronous `for (;;) tools.x()` cannot
    /// queue an unbounded number of Swift tasks before the bridge gets to say no.
    public var maxHostCalls: Int { Saturating.add(Saturating.multiply(maxToolCalls, 2), 8) }

    /// Trace events kept for one run. A call produces at most four events.
    var maxTraceEvents: Int { Saturating.add(Saturating.multiply(maxHostCalls, 4), 16) }
}

public enum ConfirmationDecision: Sendable, Equatable {
    case approved
    case denied
}

public struct ConfirmationRequest: Sendable, Equatable, Identifiable {
    public let id: Int
    public let tool: String
    public let tier: AuthorizationTier
    public let summary: String
    /// Canonical JSON of the arguments, exactly as the tool will receive them.
    public let arguments: String
}

/// Asks a human. Implementations must return eventually; the runtime does not
/// time out a confirmation on its own, but it re-checks the run's state after the
/// answer, so a late "approve" after the deadline never runs the tool.
public protocol ConfirmationProvider: Sendable {
    func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision
}

public struct DenyAllConfirmations: ConfirmationProvider {
    public init() {}
    public func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision { .denied }
}

public struct ApproveAllConfirmations: ConfirmationProvider {
    public init() {}
    public func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision { .approved }
}
