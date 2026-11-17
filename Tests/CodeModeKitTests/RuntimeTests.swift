import XCTest
@testable import CodeModeKit

final class RuntimeTests: XCTestCase {
    func runtime(_ fixture: Fixture, maxUnreclaimed: Int = 4, confirmations: any ConfirmationProvider = DenyAllConfirmations(),
                 count: EngineCount = EngineCount(), engine: @escaping @Sendable () -> any ScriptEngine) throws -> CodeModeRuntime {
        CodeModeRuntime(registry: try fixture.registry(), confirmations: confirmations, maxUnreclaimedEngines: maxUnreclaimed) {
            count.bump()
            return engine()
        }
    }

    func testCompletedRunReturnsTheScriptsValueAndTrace() async throws {
        let fixture = Fixture()
        let runtime = try runtime(fixture) {
            FakeEngine { call in
                let november = try await call("listExpenses", .object(["month": .string("2026-11")])).get()
                guard case .array(let items) = november else { return .null }
                return .object(["count": .number(Double(items.count))])
            }
        }
        let report = await runtime.run("/* fake */")
        XCTAssertEqual(report.outcome, .completed(.object(["count": .number(2)])))
        XCTAssertEqual(report.executedCalls, 1)
        XCTAssertEqual(report.trace.calls.count, 1)
        XCTAssertEqual(report.orphanedCalls, 0)
    }

    func testDeadlineEndsARunWhoseEngineYieldsAndDoesNotQuarantine() async throws {
        let fixture = Fixture()
        let runtime = try runtime(fixture) {
            FakeEngine { _ in
                try await Task.sleep(for: .seconds(30))
                return .null
            }
        }
        let report = await runtime.run("", budget: ExecutionBudget(deadline: .milliseconds(50)))
        XCTAssertEqual(report.outcome, .deadlineExceeded)
        XCTAssertLessThan(report.elapsed, .seconds(5))
        let abandoned = await runtime.abandonedEngines
        XCTAssertEqual(abandoned, 0, "an engine that honoured cancellation was reclaimed")
    }

    func testStuckEnginesAreCountedAndTheRuntimeFailsClosed() async throws {
        let fixture = Fixture()
        let count = EngineCount()
        let runtime = try runtime(fixture, maxUnreclaimed: 2, count: count) { StuckEngine() }
        let budget = ExecutionBudget(deadline: .milliseconds(20))
        let first = await runtime.run("", budget: budget)
        let second = await runtime.run("", budget: budget)
        XCTAssertEqual(first.outcome, .deadlineExceeded)
        XCTAssertEqual(second.outcome, .deadlineExceeded)
        let third = await runtime.run("", budget: budget)
        guard case .rejected(let reason) = third.outcome else { return XCTFail("expected quarantine, got \(third.outcome)") }
        XCTAssertTrue(reason.contains("quarantined"))
        XCTAssertEqual(count.value, 2, "a quarantined runtime must not create another engine")
        await runtime.acknowledgeAbandonedEngines()
        let fourth = await runtime.run("", budget: budget)
        XCTAssertEqual(fourth.outcome, .deadlineExceeded)
    }

    func testConcurrentRunsCannotAllSlipPastAdmission() async throws {
        let fixture = Fixture()
        let count = EngineCount()
        let runtime = try runtime(fixture, maxUnreclaimed: 3, count: count) { StuckEngine() }
        let budget = ExecutionBudget(deadline: .milliseconds(200))
        let outcomes = await withTaskGroup(of: RunOutcome.self) { group in
            for _ in 0..<10 { group.addTask { await runtime.run("", budget: budget).outcome } }
            var all: [RunOutcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        XCTAssertEqual(count.value, 3)
        XCTAssertEqual(outcomes.filter { $0 == .deadlineExceeded }.count, 3)
    }

    func testBudgetTripwireStopsALoopingScriptLongBeforeTheDeadline() async throws {
        let fixture = Fixture()
        let runtime = try runtime(fixture) {
            FakeEngine { call in
                while true {
                    _ = await call("listExpenses", .object(["month": .string("2026-11")]))
                    try Task.checkCancellation()
                }
            }
        }
        let report = await runtime.run("", budget: ExecutionBudget(maxToolCalls: 5, deadline: .seconds(30)))
        XCTAssertEqual(report.outcome, .budgetExhausted)
        XCTAssertEqual(report.executedCalls, 5)
        XCTAssertLessThan(report.elapsed, .seconds(5))
    }

    func testUncaughtBudgetRejectionIsReportedAsBudgetNotAsScriptFailure() async throws {
        struct Rethrown: Error {}
        let fixture = Fixture()
        let runtime = try runtime(fixture) {
            FakeEngine { call in
                while true {
                    // Like `for (;;) await tools.x()` with no try/catch: the first
                    // refusal propagates and fails the script at once.
                    if case .failure = await call("listExpenses", .object(["month": .string("2026-11")])) { throw Rethrown() }
                }
            }
        }
        for _ in 0..<20 {
            let report = await runtime.run("", budget: ExecutionBudget(maxToolCalls: 3, deadline: .seconds(30)))
            XCTAssertEqual(report.outcome, .budgetExhausted)
        }
    }

    func testCaughtBudgetRefusalIsStillABudgetStopEveryTime() async throws {
        // The script catches the refusal and returns at once, racing the tripwire.
        // The outcome must not depend on which side wins.
        let fixture = Fixture()
        let runtime = try runtime(fixture) {
            FakeEngine { call in
                while true {
                    if case .failure = await call("listExpenses", .object(["month": .string("2026-11")])) { return .string("caught") }
                }
            }
        }
        for _ in 0..<200 {
            let report = await runtime.run("", budget: ExecutionBudget(maxToolCalls: 2, deadline: .seconds(30)))
            XCTAssertEqual(report.outcome, .budgetExhausted)
        }
    }

    func testEngineHostCallLimitIsReportedAsBudget() async throws {
        struct CapEngine: ScriptEngine {
            func execute(script: String, prelude: String, limits: EngineLimits, host: @escaping ScriptHost) async throws -> String {
                throw ScriptError.hostCallLimitExceeded
            }
        }
        let runtime = try runtime(Fixture()) { CapEngine() }
        let report = await runtime.run("")
        XCTAssertEqual(report.outcome, .budgetExhausted)
    }

    func testCallerCancellationIsReportedAsCancelled() async throws {
        let fixture = Fixture()
        let runtime = try runtime(fixture) {
            FakeEngine { _ in
                try await Task.sleep(for: .seconds(30))
                return .null
            }
        }
        let task = Task { await runtime.run("", budget: ExecutionBudget(deadline: .seconds(30))) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let report = await task.value
        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertLessThan(report.elapsed, .seconds(5))
    }

    func testOversizedScriptIsRejectedWithoutCreatingAnEngine() async throws {
        let fixture = Fixture()
        let count = EngineCount()
        let runtime = try runtime(fixture, count: count) { FakeEngine { _ in .null } }
        let report = await runtime.run(String(repeating: "x", count: 101), budget: ExecutionBudget(maxScriptBytes: 100))
        XCTAssertEqual(report.outcome, .rejected("script is 101 bytes; limit is 100"))
        XCTAssertEqual(count.value, 0)
    }

    func testOversizedFinalValueFailsTheRun() async throws {
        let fixture = Fixture()
        let runtime = try runtime(fixture) { FakeEngine { _ in .string(String(repeating: "y", count: 500)) } }
        let report = await runtime.run("", budget: ExecutionBudget(resultLimits: JSONLimits(maxBytes: 100)))
        XCTAssertEqual(report.outcome, .scriptFailed("the script's result exceeds the result limits or is not JSON"))
    }

    func testNothingTheScriptDoesAfterTheReportReachesATool() async throws {
        final class Smuggled: @unchecked Sendable { var call: FakeCall? }
        let smuggled = Smuggled()
        let fixture = Fixture()
        let runtime = try runtime(fixture) {
            FakeEngine { call in
                smuggled.call = call // a script keeping a reference past its own end
                return .bool(true)
            }
        }
        let report = await runtime.run("")
        XCTAssertEqual(report.outcome, .completed(.bool(true)))
        guard let late = smuggled.call else { return XCTFail("no call captured") }
        let result = await late("deleteExpense", .object(["id": .number(1)]))
        guard case .failure(let failure) = result else { return XCTFail("a call after the run must be refused") }
        XCTAssertEqual(failure.code, .revoked)
        let ran = await fixture.deletes.value
        XCTAssertEqual(ran, 0)
    }

    func testScriptErrorsAreReported() async throws {
        struct Boom: Error {}
        let fixture = Fixture()
        let syntax = try runtime(fixture) { SyntaxFailingEngine() }
        let syntaxReport = await syntax.run("")
        XCTAssertEqual(syntaxReport.outcome, .scriptFailed("syntax error: Unexpected token"))
        let thrown = try runtime(fixture) { FakeEngine { _ in throw Boom() } }
        let thrownReport = await thrown.run("")
        guard case .scriptFailed(let message) = thrownReport.outcome else { return XCTFail("\(thrownReport.outcome)") }
        XCTAssertTrue(message.hasPrefix("uncaught:"))
    }

    struct SyntaxFailingEngine: ScriptEngine {
        func execute(script: String, prelude: String, limits: EngineLimits, host: @escaping ScriptHost) async throws -> String {
            throw ScriptError.syntax("Unexpected token")
        }
    }
}

final class ReplayTests: XCTestCase {
    static let plan: @Sendable (@escaping FakeCall) async throws -> JSONValue = { call in
        let a = try await call("listExpenses", .object(["month": .string("2026-11")])).get()
        let b = try await call("listExpenses", .object(["month": .string("2026-10")])).get()
        guard case .array(let x) = a, case .array(let y) = b else { return .null }
        return .number(Double(x.count + y.count))
    }

    func record(_ fixture: Fixture) async throws -> RunTrace {
        let runtime = CodeModeRuntime(registry: try fixture.registry(), confirmations: DenyAllConfirmations()) {
            FakeEngine(body: ReplayTests.plan)
        }
        let report = await runtime.run("")
        XCTAssertEqual(report.outcome, .completed(.number(3)))
        return report.trace
    }

    func testSamePlanReplaysIdenticallyWithoutRunningTools() async throws {
        let fixture = Fixture()
        let trace = try await record(fixture)
        let before = await fixture.expenses.value
        let verdict = await TraceReplayer(registry: try fixture.registry()).replay("", against: trace, engine: FakeEngine(body: ReplayTests.plan)).verdict
        XCTAssertEqual(verdict, .identical(calls: 2, result: .number(3)))
        let after = await fixture.expenses.value
        XCTAssertEqual(after, before, "replay must not execute tools")
    }

    func testChangedArgumentsAreReportedAtTheFirstDivergentCall() async throws {
        let fixture = Fixture()
        let trace = try await record(fixture)
        let changed = FakeEngine { call in
            _ = await call("listExpenses", .object(["month": .string("2026-11")]))
            _ = await call("listExpenses", .object(["month": .string("2026-09")]))
            return .null
        }
        let verdict = await TraceReplayer(registry: try fixture.registry()).replay("", against: trace, engine: changed).verdict
        XCTAssertEqual(verdict, .diverged(ordinal: 1,
                                          expected: #"listExpenses({"month":"2026-10"})"#,
                                          actual: #"listExpenses({"month":"2026-09"})"#))
    }

    func testSkippedCallIsReportedAsMissing() async throws {
        let fixture = Fixture()
        let trace = try await record(fixture)
        let shorter = FakeEngine { call in
            _ = await call("listExpenses", .object(["month": .string("2026-11")]))
            return .null
        }
        let verdict = await TraceReplayer(registry: try fixture.registry()).replay("", against: trace, engine: shorter).verdict
        XCTAssertEqual(verdict, .diverged(ordinal: 1, expected: #"listExpenses({"month":"2026-10"})"#, actual: "nothing"))
    }

    func testTamperedTraceIsDetected() async throws {
        let fixture = Fixture()
        var trace = try await record(fixture)
        // Edit the recorded arguments of call 0, as a corrupted or hand-edited trace would.
        trace.events = trace.events.map { event in
            guard event.ordinal == 0, case .requested(let tool, _) = event.kind else { return event }
            return TraceEvent(sequence: event.sequence, ordinal: 0, kind: .requested(tool: tool, arguments: #"{"month":"1999-01"}"#))
        }
        let verdict = await TraceReplayer(registry: try fixture.registry()).replay("", against: trace, engine: FakeEngine(body: ReplayTests.plan)).verdict
        guard case .diverged(let ordinal, _, _) = verdict else { return XCTFail("tampering must be detected: \(verdict)") }
        XCTAssertEqual(ordinal, 0)
    }

    func testDivergedReplayStopsInsteadOfLoopingUntilTheDeadline() async throws {
        let fixture = Fixture()
        let trace = try await record(fixture)
        let calls = Counter()
        // A catch-and-retry plan: after it diverges, every call is refused. The replay
        // must stop at the first divergence, not spin until the 30 s deadline.
        let looping = FakeEngine { call in
            while true {
                await calls.increment()
                _ = await call("listExpenses", .object(["month": .string("1999-01")]))
                try Task.checkCancellation()
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await TraceReplayer(registry: try fixture.registry())
            .replay("", against: trace, budget: ExecutionBudget(deadline: .seconds(30)), engine: looping)
        XCTAssertLessThan(clock.now - start, .seconds(5))
        guard case .diverged(let ordinal, _, _) = result.verdict else { return XCTFail("\(result.verdict)") }
        XCTAssertEqual(ordinal, 0)
        XCTAssertFalse(result.engineStillBusy)
        // Once replay has returned, the plan must have been stopped: no more calls.
        let atReturn = await calls.value
        try await Task.sleep(for: .milliseconds(100))
        let later = await calls.value
        XCTAssertEqual(later, atReturn)
    }

    func testTraceRoundTripsThroughCodable() async throws {
        let trace = try await record(Fixture())
        let data = try JSONEncoder().encode(trace)
        XCTAssertEqual(try JSONDecoder().decode(RunTrace.self, from: data), trace)
    }
}
