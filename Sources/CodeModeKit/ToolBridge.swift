import Foundation

/// The one door between a script and the app.
///
/// Every tool call from every concurrent promise goes through `invoke`, on this
/// actor. The ordering rules that make it safe:
///
/// 1. **Reserve before suspending.** The call-budget slot is taken synchronously,
///    before the first `await`. Actor re-entrancy means that if the check and the
///    increment were split by a suspension point, fifty `Promise.all` calls could all
///    pass the check while the count still read zero.
/// 2. **Re-check after every suspension.** A confirmation can take a human thirty
///    seconds; the run may hit its deadline meanwhile. After the answer comes back
///    the bridge checks `revoked` again, so a late "approve" never runs the tool.
/// 3. **Results after revocation are dropped.** A tool already executing when the
///    run ends finishes (Swift cannot un-run it) but its result is recorded as
///    dropped and never reaches the script.
public actor ToolBridge {
    private let registry: ToolRegistry
    private let scope: CapabilityScope
    private let budget: ExecutionBudget
    private let confirmations: any ConfirmationProvider
    private let tripwire: AsyncStream<RunStopReason>.Continuation?

    private var attempts = 0
    private var executed = 0
    private var inFlight = 0
    private var revoked = false
    private var budgetTripped = false
    private var recorder: TraceRecorder

    public init(
        registry: ToolRegistry,
        scope: CapabilityScope,
        budget: ExecutionBudget,
        confirmations: any ConfirmationProvider,
        tripwire: AsyncStream<RunStopReason>.Continuation? = nil
    ) {
        self.registry = registry
        self.scope = scope
        self.budget = budget
        self.confirmations = confirmations
        self.tripwire = tripwire
        self.recorder = TraceRecorder(capacity: budget.maxTraceEvents)
    }

    public func invoke(_ call: HostCall) async -> Result<String, ToolCallFailure> {
        let ordinal = call.ordinal
        let parsed = try? JSONValue.parse(call.argumentsJSON, limits: budget.argumentLimits)
        // Unparseable arguments are recorded as a bounded prefix so a hostile script
        // cannot grow the trace by sending megabytes of garbage.
        recorder.record(ordinal, .requested(
            tool: RunTrace.recordedToolName(call.tool),
            arguments: parsed?.canonicalText() ?? RunTrace.recordedRawArguments(call.argumentsJSON)
        ))

        func refuse(_ code: ToolCallFailure.Code, _ message: String) -> Result<String, ToolCallFailure> {
            let failure = ToolCallFailure(code, message)
            recorder.record(ordinal, .failed(failure))
            return .failure(failure)
        }

        guard !revoked else { return refuse(.revoked, "the run has ended") }

        // (1) Reserve the budget slot before any suspension point.
        guard attempts < budget.maxToolCalls else {
            revoked = true
            budgetTripped = true
            tripwire?.yield(.budgetExhausted)
            return refuse(.budgetExhausted, "tool-call budget of \(budget.maxToolCalls) exhausted")
        }
        attempts += 1

        guard let tool = registry.tool(named: call.tool) else {
            return refuse(.unknownTool, "no tool named \(call.tool)")
        }
        let descriptor = tool.descriptor
        guard scope.allows(descriptor) else {
            return refuse(.notInScope, "\(call.tool) is not available in this run")
        }
        guard let arguments = parsed else {
            return refuse(.invalidArguments, Self.describeParseFailure(call.argumentsJSON, limits: budget.argumentLimits))
        }
        let issues = descriptor.input.validate(arguments)
        guard issues.isEmpty else {
            return refuse(.invalidArguments, issues.map(\.description).joined(separator: "; "))
        }
        let canonical = arguments.canonicalText()

        if scope.needsConfirmation(descriptor) {
            recorder.record(ordinal, .confirmationRequested)
            let request = ConfirmationRequest(id: ordinal, tool: descriptor.name, tier: descriptor.tier, summary: descriptor.summary, arguments: canonical)
            let decision = await confirmations.confirm(request)
            recorder.record(ordinal, .confirmationResolved(approved: decision == .approved))
            // (2) Suspension point above: the run may have ended while a human decided.
            guard !revoked else { return refuse(.revoked, "the run ended before confirmation arrived") }
            guard decision == .approved else { return refuse(.denied, "the user declined \(descriptor.name)") }
        }

        inFlight += 1
        executed += 1
        let outcome: Result<Data, Error>
        do {
            outcome = .success(try await tool.invoke(Data(canonical.utf8)))
        } catch {
            outcome = .failure(error)
        }
        inFlight -= 1

        // (3) Suspension point above: drop results that arrive after the run ended.
        guard !revoked else {
            recorder.record(ordinal, .lateResultDropped)
            return .failure(ToolCallFailure(.revoked, "the run has ended"))
        }

        switch outcome {
        case .failure(let error):
            let message = (error as? ModelFacingError)?.modelFacingMessage ?? "\(descriptor.name) failed"
            return refuse(.toolError, message)
        case .success(let data):
            guard data.count <= budget.resultLimits.maxBytes else {
                return refuse(.resultTooLarge, "\(descriptor.name) returned \(data.count) bytes; limit is \(budget.resultLimits.maxBytes)")
            }
            guard let value = try? JSONValue.parse(data, limits: budget.resultLimits),
                  descriptor.output.validate(value).isEmpty else {
                return refuse(.toolError, "\(descriptor.name) returned a value that does not match its declared output")
            }
            let text = value.canonicalText()
            recorder.record(ordinal, .succeeded(result: text))
            return .success(text)
        }
    }

    /// Ends the run. Returns how many tool calls were still executing; their side
    /// effects may still happen, but their results will be dropped.
    @discardableResult
    public func revoke() -> Int {
        revoked = true
        return inFlight
    }

    public var trace: RunTrace { recorder.trace }
    /// True once a call has been refused for exceeding the budget.
    public var didExhaustBudget: Bool { budgetTripped }
    public var executedCalls: Int { executed }
    public var attemptedCalls: Int { attempts }

    private static func describeParseFailure(_ text: String, limits: JSONLimits) -> String {
        do {
            _ = try JSONValue.parse(text, limits: limits)
            return "arguments could not be read"
        } catch let error as JSONLimitError {
            switch error {
            case .tooLarge(let bytes, let limit): return "arguments are \(bytes) bytes; limit is \(limit)"
            case .tooDeep(let limit): return "arguments nest deeper than \(limit) levels"
            case .malformed: return "arguments are not valid JSON"
            }
        } catch {
            return "arguments could not be read"
        }
    }
}

/// Why a run stopped before the script finished on its own.
public enum RunStopReason: Sendable, Equatable {
    case budgetExhausted
    case deadlineExceeded
}
