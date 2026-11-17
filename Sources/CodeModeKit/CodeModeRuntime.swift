import Foundation

public enum RunOutcome: Sendable, Equatable {
    /// The script finished and returned this value.
    case completed(JSONValue)
    /// The script threw, failed to compile, or returned something unusable.
    case scriptFailed(String)
    /// The tool-call budget ran out; the run was stopped at the first refused call.
    case budgetExhausted
    /// The wall-clock deadline passed.
    case deadlineExceeded
    /// The run never started (script too large, runtime quarantined).
    case rejected(String)
    /// The task calling `run` was cancelled before the run finished.
    case cancelled
}

public struct RunReport: Sendable, Equatable {
    public let outcome: RunOutcome
    public let trace: RunTrace
    /// Tool calls that actually executed (reached the tool's `call`).
    public let executedCalls: Int
    /// Calls that consumed budget: everything the bridge admitted for checking,
    /// including ones then refused as unknown, out of scope, invalid or denied. Calls
    /// refused because the budget was already spent or the run had ended don't count.
    public let attemptedCalls: Int
    /// Calls still executing when the run ended. Their side effects can still land;
    /// their results are discarded.
    public let orphanedCalls: Int
    public let elapsed: Duration
}

/// Runs model-written scripts against an app's typed tools.
///
/// One run = one fresh engine + one `ToolBridge`. The run ends at whichever comes
/// first: the script settles, the deadline passes, or the bridge trips the budget.
/// In every case the bridge is revoked *before* the report is built, so nothing a
/// script does after the report exists can reach a tool.
///
/// **Engines that may still be running are counted.** Public JavaScriptCore API has
/// no way to interrupt a synchronous `while (true) {}`; when the deadline fires, the
/// engine's thread may keep spinning. The engine reports whether that happened
/// (`EngineCancelled.stillBusy`). The runtime cannot reclaim such an engine, so it
/// admits a new run only while fewer than `maxUnreclaimedEngines` engines are in
/// flight or were abandoned busy. Past that it refuses (fails closed) until the host
/// app decides what to do, for example by restarting the process.
public actor CodeModeRuntime {
    private let registry: ToolRegistry
    private let engineFactory: @Sendable () -> any ScriptEngine
    private let confirmations: any ConfirmationProvider
    private let maxUnreclaimedEngines: Int

    private var inFlight = 0
    private var abandoned = 0

    public init(
        registry: ToolRegistry,
        confirmations: any ConfirmationProvider,
        maxUnreclaimedEngines: Int = 4,
        engineFactory: @escaping @Sendable () -> any ScriptEngine
    ) {
        self.registry = registry
        self.confirmations = confirmations
        self.maxUnreclaimedEngines = max(1, maxUnreclaimedEngines)
        self.engineFactory = engineFactory
    }

    /// Engines that were cancelled while their script was still running synchronously.
    /// Permanent until `acknowledgeAbandonedEngines()`, even if such a script later
    /// returns: the runtime cannot observe that, so it assumes the worst.
    public var abandonedEngines: Int { abandoned }

    public func declarations(in scope: CapabilityScope) -> String {
        registry.typeScriptDeclarations(in: scope)
    }

    public func run(_ script: String, scope: CapabilityScope = CapabilityScope(), budget: ExecutionBudget = ExecutionBudget()) async -> RunReport {
        let clock = ContinuousClock()
        let start = clock.now
        let scriptBytes = script.utf8.count
        guard scriptBytes <= budget.maxScriptBytes else {
            return Self.rejected("script is \(scriptBytes) bytes; limit is \(budget.maxScriptBytes)", elapsed: clock.now - start)
        }
        // Admission is decided and recorded with no suspension point in between, so
        // concurrent run() calls cannot all pass the check at once.
        guard Saturating.add(inFlight, abandoned) < maxUnreclaimedEngines else {
            return Self.rejected("runtime quarantined: \(abandoned) engine(s) abandoned at a deadline", elapsed: clock.now - start)
        }
        inFlight += 1

        let (stops, stopContinuation) = AsyncStream<RunStopReason>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let bridge = ToolBridge(registry: registry, scope: scope, budget: budget, confirmations: confirmations, tripwire: stopContinuation)
        let engine = engineFactory()
        let prelude = registry.prelude(in: scope)
        let limits = EngineLimits(maxHostCalls: budget.maxHostCalls)
        let deadline = budget.deadline

        enum Event: Sendable {
            case settled(Result<String, ScriptError>)
            case stopped(RunStopReason)
            /// The engine gave up after cancellation; `busy` says whether its script
            /// was still running synchronously and so could not be reclaimed.
            case released(busy: Bool)
            case cancelled
        }

        let (first, engineBusy, orphaned): (Event?, Bool, Int) = await withTaskGroup(of: Event.self) { group in
            group.addTask {
                do {
                    let text = try await engine.execute(script: script, prelude: prelude, limits: limits) { call in
                        await bridge.invoke(call)
                    }
                    return .settled(.success(text))
                } catch let error as ScriptError {
                    return .settled(.failure(error))
                } catch let cancelled as EngineCancelled {
                    return .released(busy: cancelled.stillBusy)
                } catch {
                    // Anything else after cancellation is treated as "may still be running".
                    return Task.isCancelled ? .released(busy: true) : .settled(.failure(.uncaught("\(error)")))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: deadline, clock: clock)
                    return .stopped(.deadlineExceeded)
                } catch {
                    return .cancelled // something else finished first
                }
            }
            group.addTask {
                for await reason in stops { return .stopped(reason) }
                return .cancelled
            }
            var first: Event?
            var busy = false
            while first == nil, let next = await group.next() {
                switch next {
                case .settled, .stopped: first = next
                case .released(let isBusy): busy = isBusy
                case .cancelled: break
                }
            }
            // Revoke before cancelling anything else: from here on no tool runs.
            let orphaned = await bridge.revoke()
            group.cancelAll()
            stopContinuation.finish()
            // The engine contract says execute() returns promptly on cancellation, so
            // this drains even if the script is stuck in a synchronous loop.
            for await next in group {
                if case .released(let isBusy) = next { busy = isBusy }
            }
            return (first, busy, orphaned)
        }

        inFlight -= 1
        let outcome: RunOutcome
        if engineBusy { abandoned = Saturating.add(abandoned, 1) }
        // A script that does not catch the over-budget rejection fails at about the
        // same moment the tripwire fires. Classify by cause, not by which won the race.
        let exhausted = await bridge.didExhaustBudget
        switch first {
        case .none, .released, .cancelled:
            // Only possible when the caller's task was cancelled.
            outcome = .cancelled
        case .stopped(.deadlineExceeded):
            outcome = .deadlineExceeded
        case .settled where exhausted, .settled(.failure(.hostCallLimitExceeded)):
            // Classified by cause, not by which side won the race: once any call has
            // been refused for budget, the run is a budget stop even if the script
            // caught the refusal and returned first.
            outcome = .budgetExhausted
        case .stopped(.budgetExhausted):
            outcome = .budgetExhausted
        case .settled(.failure(let error)):
            outcome = .scriptFailed(Self.describe(error))
        case .settled(.success(let text)):
            do {
                outcome = .completed(try JSONValue.parse(text, limits: budget.resultLimits))
            } catch {
                outcome = .scriptFailed("the script's result exceeds the result limits or is not JSON")
            }
        }
        return RunReport(
            outcome: outcome,
            trace: await bridge.trace,
            executedCalls: await bridge.executedCalls,
            attemptedCalls: await bridge.attemptedCalls,
            orphanedCalls: orphaned,
            elapsed: clock.now - start
        )
    }

    /// For the host app's "reset" path after it has dealt with abandoned engines
    /// (for example after a process restart has been ruled out). Deliberately explicit.
    public func acknowledgeAbandonedEngines() { abandoned = 0 }

    private static func rejected(_ reason: String, elapsed: Duration) -> RunReport {
        RunReport(outcome: .rejected(reason), trace: RunTrace(), executedCalls: 0, attemptedCalls: 0, orphanedCalls: 0, elapsed: elapsed)
    }

    static func describe(_ error: ScriptError) -> String {
        switch error {
        case .syntax(let message): return "syntax error: \(message)"
        case .uncaught(let message): return "uncaught: \(message)"
        case .engineUnavailable(let message): return "engine unavailable: \(message)"
        case .hostCallLimitExceeded: return "host-call limit exceeded"
        }
    }
}
