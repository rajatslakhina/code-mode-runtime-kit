import Foundation

public struct ReplayResult: Sendable, Equatable {
    public let verdict: ReplayVerdict
    /// True when the replayed script was still running synchronously when the replay
    /// gave up (deadline). Like a stuck run, its thread cannot be reclaimed. Replays
    /// do not share a runtime's quarantine, so run them in tests and CI, where the
    /// process is short-lived, not in an app's request path.
    public let engineStillBusy: Bool
}

public enum ReplayVerdict: Sendable, Equatable {
    /// The script made exactly the recorded calls, by ordinal, and finished.
    case identical(calls: Int, result: JSONValue)
    /// The script asked for something the trace does not contain, or skipped a call
    /// it contains. `expected`/`actual` read like `listExpenses({"month":"2026-11"})`;
    /// "nothing" marks a missing side.
    case diverged(ordinal: Int, expected: String, actual: String)
    /// The script failed for a reason other than divergence.
    case scriptFailed(String)
}

/// Re-runs a script against a recorded trace, serving every tool call from the
/// recording. No tool executes, so a bug report's trace can be replayed safely
/// against production code, and a changed prompt or model version can be checked
/// for "does it still make the same calls?" without touching data.
///
/// Calls are matched by the engine's ordinal (program order), not by arrival order
/// at the bridge, so a plan using `Promise.all` replays deterministically.
///
/// Replay is meant for runs that settled on their own (completed or failed). A
/// call that never received a response (still running at a deadline, or past a
/// budget stop) is not in `RunTrace.calls`, so replaying such a run reports a
/// divergence or a failure at that point.
public struct TraceReplayer: Sendable {
    private let registry: ToolRegistry

    public init(registry: ToolRegistry) { self.registry = registry }

    public func replay(
        _ script: String,
        against trace: RunTrace,
        scope: CapabilityScope = CapabilityScope(),
        budget: ExecutionBudget = ExecutionBudget(),
        engine: any ScriptEngine
    ) async -> ReplayResult {
        let (divergences, divergenceContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let ledger = ReplayLedger(recorded: trace.calls, argumentLimits: budget.argumentLimits, onDivergence: divergenceContinuation)
        let prelude = registry.prelude(in: scope)
        let limits = EngineLimits(maxHostCalls: budget.maxHostCalls)
        let deadline = budget.deadline

        enum Event: Sendable {
            case settled(Result<String, ScriptError>)
            case stop
            case released(busy: Bool)
            case cancelled
        }

        // Same shape as CodeModeRuntime.run: the replay stops at the first of
        // settle / deadline / divergence, and the engine is cancelled right away, so a
        // diverged plan never keeps looping against refusals.
        let (outcome, busy): (Result<String, ScriptError>?, Bool) = await withTaskGroup(of: Event.self) { group in
            group.addTask {
                do {
                    return .settled(.success(try await engine.execute(script: script, prelude: prelude, limits: limits) { call in
                        await ledger.answer(call)
                    }))
                } catch let error as ScriptError {
                    return .settled(.failure(error))
                } catch let cancelled as EngineCancelled {
                    return .released(busy: cancelled.stillBusy)
                } catch {
                    return Task.isCancelled ? .released(busy: true) : .settled(.failure(.uncaught("\(error)")))
                }
            }
            group.addTask {
                do { try await Task.sleep(for: deadline) } catch { return .cancelled }
                return .stop
            }
            group.addTask {
                for await _ in divergences { return .stop }
                return .cancelled
            }
            var outcome: Result<String, ScriptError>?
            var busy = false
            var decided = false
            while !decided, let next = await group.next() {
                switch next {
                case .settled(let result): outcome = result; decided = true
                case .stop: decided = true
                case .released(let isBusy): busy = isBusy
                case .cancelled: break
                }
            }
            group.cancelAll()
            divergenceContinuation.finish()
            for await next in group {
                if case .released(let isBusy) = next { busy = isBusy }
            }
            return (outcome, busy)
        }

        func result(_ verdict: ReplayVerdict) -> ReplayResult { ReplayResult(verdict: verdict, engineStillBusy: busy) }
        if let divergence = await ledger.divergence { return result(divergence) }
        if let missing = await ledger.firstUnanswered, outcome != nil {
            return result(.diverged(ordinal: missing.ordinal, expected: Self.describe(missing.tool, missing.arguments), actual: "nothing"))
        }
        switch outcome {
        case .none:
            return result(.scriptFailed("replay exceeded the deadline"))
        case .failure(let error):
            return result(.scriptFailed(CodeModeRuntime.describe(error)))
        case .success(let text):
            guard let value = try? JSONValue.parse(text, limits: budget.resultLimits) else {
                return result(.scriptFailed("the script's result exceeds the result limits or is not JSON"))
            }
            return result(.identical(calls: await ledger.answeredCount, result: value))
        }
    }

    static func describe(_ tool: String, _ arguments: String) -> String { "\(tool)(\(arguments))" }
}

private actor ReplayLedger {
    private let recorded: [Int: RecordedCall]
    private let argumentLimits: JSONLimits
    private var answered: Set<Int> = []
    private let onDivergence: AsyncStream<Void>.Continuation
    private(set) var divergence: ReplayVerdict?

    init(recorded: [RecordedCall], argumentLimits: JSONLimits, onDivergence: AsyncStream<Void>.Continuation) {
        self.onDivergence = onDivergence
        var byOrdinal: [Int: RecordedCall] = [:]
        for call in recorded { byOrdinal[call.ordinal] = call }
        self.recorded = byOrdinal
        self.argumentLimits = argumentLimits
    }

    var answeredCount: Int { answered.count }

    var firstUnanswered: RecordedCall? {
        recorded.keys.sorted().first { !answered.contains($0) }.flatMap { recorded[$0] }
    }

    func answer(_ call: HostCall) -> Result<String, ToolCallFailure> {
        let tool = RunTrace.recordedToolName(call.tool)
        let arguments = RunTrace.recordedArguments(call.argumentsJSON, limits: argumentLimits)
        let actual = TraceReplayer.describe(tool, arguments)
        guard let expected = recorded[call.ordinal] else {
            noteDivergence(call.ordinal, expected: "nothing", actual: actual)
            return .failure(ToolCallFailure(.revoked, "replay diverged"))
        }
        guard expected.tool == tool, expected.arguments == arguments else {
            noteDivergence(call.ordinal, expected: TraceReplayer.describe(expected.tool, expected.arguments), actual: actual)
            return .failure(ToolCallFailure(.revoked, "replay diverged"))
        }
        answered.insert(call.ordinal)
        return expected.response
    }

    /// Keeps the lowest-ordinal divergence, so the report points at the first point
    /// the plan went somewhere new, whatever order concurrent calls arrived in.
    private func noteDivergence(_ ordinal: Int, expected: String, actual: String) {
        if case .diverged(let existing, _, _) = divergence, existing <= ordinal { return }
        divergence = .diverged(ordinal: ordinal, expected: expected, actual: actual)
        onDivergence.yield()
    }
}
