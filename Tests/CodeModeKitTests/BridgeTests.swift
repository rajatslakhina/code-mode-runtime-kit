import XCTest
@testable import CodeModeKit

/// Anything that admits tool calls. The real `ToolBridge` and a deliberately
/// broken one both conform, so the budget harness below is shown to catch the bug
/// it exists to catch, not just to pass.
protocol ToolInvoking: Sendable {
    func invoke(_ call: HostCall) async -> Result<String, ToolCallFailure>
}

extension ToolBridge: ToolInvoking {}

/// The classic actor re-entrancy bug: checks the budget, suspends while the tool
/// runs, and only counts the call afterwards. Every concurrent caller passes the
/// check while the count still reads zero.
actor CheckAfterAwaitBridge: ToolInvoking {
    let tool: GatedTool
    let budget: Int
    var executed = 0

    init(tool: GatedTool, budget: Int) {
        self.tool = tool
        self.budget = budget
    }

    func invoke(_ call: HostCall) async -> Result<String, ToolCallFailure> {
        guard executed < budget else { return .failure(ToolCallFailure(.budgetExhausted, "")) }
        _ = try? await tool.call(.init())
        executed += 1
        return .success("{}")
    }
}

final class BridgeTests: XCTestCase {
    /// Fires `callers` concurrent calls at `invoker`, holds every call that reaches
    /// the tool at a gate until all callers have either arrived or been refused,
    /// then returns how many calls reached the tool.
    func callsReachingTool(_ invoker: any ToolInvoking, fixture: Fixture, callers: Int) async -> Int {
        let refused = Counter()
        let calls = (0..<callers).map { HostCall(ordinal: $0, tool: "gated", argumentsJSON: "{}") }
        async let all: Void = withTaskGroup(of: Void.self) { group in
            for call in calls {
                group.addTask {
                    if case .failure = await invoker.invoke(call) { await refused.increment() }
                }
            }
        }
        let settled = await eventually {
            let arrived = await fixture.gate.arrivals
            let refusedCount = await refused.value
            return arrived + refusedCount == callers
        }
        XCTAssertTrue(settled, "callers never settled")
        await fixture.gate.open()
        await all
        return await fixture.gated.value
    }

    func testBudgetHoldsUnderFiftyConcurrentCalls() async throws {
        let fixture = Fixture()
        let budget = ExecutionBudget(maxToolCalls: 10)
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: budget, confirmations: DenyAllConfirmations())
        let reached = await callsReachingTool(bridge, fixture: fixture, callers: 50)
        XCTAssertEqual(reached, 10)
        let attempted = await bridge.attemptedCalls
        let executed = await bridge.executedCalls
        XCTAssertEqual(attempted, 10)
        XCTAssertEqual(executed, 10)
    }

    func testHarnessCatchesTheCheckAfterAwaitBug() async {
        let fixture = Fixture()
        let broken = CheckAfterAwaitBridge(tool: GatedTool(gate: fixture.gate, counter: fixture.gated), budget: 10)
        let reached = await callsReachingTool(broken, fixture: fixture, callers: 50)
        XCTAssertEqual(reached, 50, "every caller passes the broken check while the count still reads zero")
    }

    func testFirstCallOverBudgetTripsTheRunAndRevokesTheBridge() async throws {
        let fixture = Fixture()
        let (stops, continuation) = AsyncStream<RunStopReason>.makeStream()
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(),
                                budget: ExecutionBudget(maxToolCalls: 1), confirmations: DenyAllConfirmations(), tripwire: continuation)
        let ok = await bridge.invoke(HostCall(ordinal: 0, tool: "listExpenses", argumentsJSON: #"{"month":"2026-11"}"#))
        XCTAssertNotNil(try? ok.get())
        let over = await bridge.invoke(HostCall(ordinal: 1, tool: "listExpenses", argumentsJSON: #"{"month":"2026-11"}"#))
        XCTAssertEqual(over, .failure(ToolCallFailure(.budgetExhausted, "tool-call budget of 1 exhausted")))
        continuation.finish()
        var reasons: [RunStopReason] = []
        for await reason in stops { reasons.append(reason) }
        XCTAssertEqual(reasons, [.budgetExhausted])
        // Revoked: even a call that would fit is refused now.
        let after = await bridge.invoke(HostCall(ordinal: 2, tool: "listExpenses", argumentsJSON: #"{"month":"2026-11"}"#))
        guard case .failure(let failure) = after else { return XCTFail("expected refusal") }
        XCTAssertEqual(failure.code, .revoked)
    }

    func testRefusedCallsStillConsumeBudget() async throws {
        let fixture = Fixture()
        let bridge = ToolBridge(registry: try fixture.registry(), scope: .readOnly,
                                budget: ExecutionBudget(maxToolCalls: 3), confirmations: DenyAllConfirmations())
        let unknown = await bridge.invoke(HostCall(ordinal: 0, tool: "nope", argumentsJSON: "{}"))
        let scoped = await bridge.invoke(HostCall(ordinal: 1, tool: "deleteExpense", argumentsJSON: #"{"id":1}"#))
        let invalid = await bridge.invoke(HostCall(ordinal: 2, tool: "listExpenses", argumentsJSON: #"{"month":7}"#))
        let fourth = await bridge.invoke(HostCall(ordinal: 3, tool: "listExpenses", argumentsJSON: #"{"month":"2026-11"}"#))
        XCTAssertEqual(unknown, .failure(ToolCallFailure(.unknownTool, "no tool named nope")))
        XCTAssertEqual(scoped, .failure(ToolCallFailure(.notInScope, "deleteExpense is not available in this run")))
        XCTAssertEqual(invalid, .failure(ToolCallFailure(.invalidArguments, "$.month: expected string")))
        guard case .failure(let failure) = fourth else { return XCTFail("expected budget refusal") }
        XCTAssertEqual(failure.code, .budgetExhausted)
        let ran = await fixture.expenses.value
        XCTAssertEqual(ran, 0)
        let deleted = await fixture.deletes.value
        XCTAssertEqual(deleted, 0)
    }

    func testDeniedConfirmationNeverRunsTheTool() async throws {
        let fixture = Fixture()
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: ExecutionBudget(), confirmations: DenyAllConfirmations())
        let result = await bridge.invoke(HostCall(ordinal: 0, tool: "deleteExpense", argumentsJSON: #"{"id":2}"#))
        XCTAssertEqual(result, .failure(ToolCallFailure(.denied, "the user declined deleteExpense")))
        let deleted = await fixture.deletes.value
        XCTAssertEqual(deleted, 0)
        let kinds = await bridge.trace.events.map(\.kind)
        XCTAssertEqual(kinds, [
            .requested(tool: "deleteExpense", arguments: #"{"id":2}"#),
            .confirmationRequested,
            .confirmationResolved(approved: false),
            .failed(ToolCallFailure(.denied, "the user declined deleteExpense")),
        ])
    }

    func testApprovalThatArrivesAfterTheRunEndedNeverRunsTheTool() async throws {
        let fixture = Fixture()
        let human = ParkedConfirmations()
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: ExecutionBudget(), confirmations: human)
        async let result = bridge.invoke(HostCall(ordinal: 0, tool: "deleteExpense", argumentsJSON: #"{"id":2}"#))
        let asked = await eventually { await human.asked == 1 }
        XCTAssertTrue(asked)
        await bridge.revoke()          // deadline passes while the human is deciding
        await human.answerAll(.approved) // ...and then they tap Approve
        let outcome = await result
        guard case .failure(let failure) = outcome else { return XCTFail("tool must not run") }
        XCTAssertEqual(failure.code, .revoked)
        let deleted = await fixture.deletes.value
        XCTAssertEqual(deleted, 0)
    }

    func testApprovedConfirmationRunsTheToolWithCanonicalArguments() async throws {
        let fixture = Fixture()
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: ExecutionBudget(), confirmations: ApproveAllConfirmations())
        let result = await bridge.invoke(HostCall(ordinal: 0, tool: "deleteExpense", argumentsJSON: #"{ "id" : 2 }"#))
        XCTAssertEqual(result, .success(#"{"ok":true}"#))
        let deleted = await fixture.deletes.value
        XCTAssertEqual(deleted, 1)
    }

    func testResultThatArrivesAfterRevocationIsDropped() async throws {
        let fixture = Fixture()
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: ExecutionBudget(), confirmations: DenyAllConfirmations())
        async let result = bridge.invoke(HostCall(ordinal: 0, tool: "gated", argumentsJSON: "{}"))
        let arrived = await eventually { await fixture.gate.arrivals == 1 }
        XCTAssertTrue(arrived)
        let orphaned = await bridge.revoke()
        XCTAssertEqual(orphaned, 1)
        await fixture.gate.open()
        let outcome = await result
        guard case .failure(let failure) = outcome else { return XCTFail("late result must not reach the script") }
        XCTAssertEqual(failure.code, .revoked)
        let last = await bridge.trace.events.last?.kind
        XCTAssertEqual(last, .lateResultDropped)
    }

    func testToolErrorsOnlyExposeModelFacingMessages() async throws {
        let fixture = Fixture()
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: ExecutionBudget(), confirmations: DenyAllConfirmations())
        let safe = await bridge.invoke(HostCall(ordinal: 0, tool: "failing", argumentsJSON: #"{"safe":true}"#))
        let secret = await bridge.invoke(HostCall(ordinal: 1, tool: "failing", argumentsJSON: #"{"safe":false}"#))
        XCTAssertEqual(safe, .failure(ToolCallFailure(.toolError, "card declined")))
        XCTAssertEqual(secret, .failure(ToolCallFailure(.toolError, "failing failed")))
        let trace = await bridge.trace
        XCTAssertFalse(String(describing: trace).contains("hunter2"))
    }

    func testOversizedAndSchemaViolatingResultsAreRefused() async throws {
        let fixture = Fixture()
        let budget = ExecutionBudget(resultLimits: JSONLimits(maxBytes: 100, maxDepth: 8))
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: budget, confirmations: DenyAllConfirmations())
        let big = await bridge.invoke(HostCall(ordinal: 0, tool: "big", argumentsJSON: #"{"bytes":500}"#))
        guard case .failure(let bigFailure) = big else { return XCTFail("expected refusal") }
        XCTAssertEqual(bigFailure.code, .resultTooLarge)
        let lying = await bridge.invoke(HostCall(ordinal: 1, tool: "lying", argumentsJSON: "{}"))
        XCTAssertEqual(lying, .failure(ToolCallFailure(.toolError, "lying returned a value that does not match its declared output")))
    }

    func testMalformedAndOversizedArgumentsAreRefusedWithReasons() async throws {
        let fixture = Fixture()
        let budget = ExecutionBudget(argumentLimits: JSONLimits(maxBytes: 64, maxDepth: 2))
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: budget, confirmations: DenyAllConfirmations())
        let malformed = await bridge.invoke(HostCall(ordinal: 0, tool: "listExpenses", argumentsJSON: "{month"))
        let deep = await bridge.invoke(HostCall(ordinal: 1, tool: "listExpenses", argumentsJSON: #"{"month":[[["x"]]]}"#))
        let large = await bridge.invoke(HostCall(ordinal: 2, tool: "listExpenses", argumentsJSON: "\"" + String(repeating: "a", count: 1_000) + "\""))
        XCTAssertEqual(malformed, .failure(ToolCallFailure(.invalidArguments, "arguments are not valid JSON")))
        XCTAssertEqual(deep, .failure(ToolCallFailure(.invalidArguments, "arguments nest deeper than 2 levels")))
        XCTAssertEqual(large, .failure(ToolCallFailure(.invalidArguments, "arguments are 1002 bytes; limit is 64")))
        // The trace keeps only a bounded prefix of unparseable input.
        let recorded = await bridge.trace.events.compactMap { event -> String? in
            if case .requested(_, let arguments) = event.kind { return arguments } else { return nil }
        }
        XCTAssertEqual(recorded.map(\.utf8.count).max(), 256)
    }

    func testTraceSequenceIsGapFreeUnderConcurrentCalls() async throws {
        let fixture = Fixture()
        let bridge = ToolBridge(registry: try fixture.registry(), scope: CapabilityScope(), budget: ExecutionBudget(), confirmations: ApproveAllConfirmations())
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    let tool = i % 3 == 0 ? "deleteExpense" : "listExpenses"
                    let args = i % 3 == 0 ? #"{"id":1}"# : #"{"month":"2026-11"}"#
                    _ = await bridge.invoke(HostCall(ordinal: i, tool: tool, argumentsJSON: args))
                }
            }
        }
        let sequences = await bridge.trace.events.map(\.sequence)
        XCTAssertEqual(sequences, Array(0..<sequences.count))
        let calls = await bridge.trace.calls
        XCTAssertEqual(calls.map(\.ordinal), Array(0..<12))
    }
}
