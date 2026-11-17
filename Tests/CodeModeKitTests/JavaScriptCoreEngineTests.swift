#if canImport(JavaScriptCore)
import XCTest
import JavaScriptCore
@testable import CodeModeKit

/// End-to-end tests against real JavaScriptCore. Apple platforms only; the same
/// runtime and bridge logic is covered on Linux through `FakeEngine`.
final class JavaScriptCoreEngineTests: XCTestCase {
    func runtime(_ fixture: Fixture, confirmations: any ConfirmationProvider = DenyAllConfirmations()) throws -> CodeModeRuntime {
        CodeModeRuntime(registry: try fixture.registry(), confirmations: confirmations) { JavaScriptCoreEngine() }
    }

    func testParallelPlanRunsAndNumbersCallsInProgramOrder() async throws {
        let fixture = Fixture()
        let report = try await runtime(fixture).run("""
            const [nov, oct] = await Promise.all([
              tools.listExpenses({ month: "2026-11" }),
              tools.listExpenses({ month: "2026-10" }),
            ]);
            const total = [...nov, ...oct].reduce((sum, e) => sum + e.cents, 0);
            return { total, count: nov.length + oct.length };
            """)
        XCTAssertEqual(report.outcome, .completed(.object(["total": .number(3_650), "count": .number(3)])))
        XCTAssertEqual(report.trace.calls.map(\.ordinal), [0, 1])
        XCTAssertEqual(report.trace.calls.map(\.arguments), [#"{"month":"2026-11"}"#, #"{"month":"2026-10"}"#])
        let ran = await fixture.expenses.value
        XCTAssertEqual(ran, 2)
    }

    func testTheContextHasNoAmbientAuthority() async throws {
        let report = try await runtime(Fixture()).run("""
            const probes = {
              fetch: typeof fetch, XMLHttpRequest: typeof XMLHttpRequest, setTimeout: typeof setTimeout,
              require: typeof require, process: typeof process, eval: typeof eval,
              Function: typeof Function,
            };
            let dynamic = "allowed";
            try { (function () {}).constructor("return 1")(); } catch (e) { dynamic = e instanceof TypeError ? "blocked" : "other"; }
            for (const f of [async function () {}, function* () {}, async function* () {}]) {
              try { f.constructor("return 1"); dynamic += "+allowed"; } catch (e) { dynamic += e instanceof TypeError ? "+blocked" : "+other"; }
            }
            probes.dynamic = dynamic;
            let frozen = false;
            try { tools.listExpenses = () => 1; } catch (e) { frozen = e instanceof TypeError; }
            probes.frozen = frozen;
            return probes;
            """)
        XCTAssertEqual(report.outcome, .completed(.object([
            "fetch": .string("undefined"), "XMLHttpRequest": .string("undefined"), "setTimeout": .string("undefined"),
            "require": .string("undefined"), "process": .string("undefined"), "eval": .string("undefined"),
            "Function": .string("undefined"), "dynamic": .string("blocked+blocked+blocked+blocked"), "frozen": .bool(true),
        ])))
    }

    func testTheRunAddsNoGlobalsToAPlainContext() async throws {
        // Whatever a fresh JSContext exposes is the baseline; the runtime may only
        // remove from it (eval, Function), never add a host function or helper.
        let names = "JSON.stringify(Object.getOwnPropertyNames(globalThis).sort())"
        guard let fresh = JSContext()?.evaluateScript(names)?.toString(),
              case .array(let baseline)? = try? JSONValue.parse(fresh, limits: JSONLimits()) else {
            return XCTFail("could not read a fresh context's globals")
        }
        let report = try await runtime(Fixture()).run("return Object.getOwnPropertyNames(globalThis).sort();")
        guard case .completed(.array(let inRun)) = report.outcome else { return XCTFail("\(report.outcome)") }
        XCTAssertFalse(inRun.isEmpty)
        XCTAssertTrue(Set(inRun).isSubset(of: Set(baseline)), "added: \(Set(inRun).subtracting(Set(baseline)))")
        XCTAssertFalse(inRun.contains(.string("eval")))
    }

    func testOutOfScopeToolsDoNotExistInTheScript() async throws {
        let fixture = Fixture()
        let report = try await runtime(fixture).run(
            "return { del: typeof tools.deleteExpense, list: typeof tools.listExpenses };",
            scope: .readOnly
        )
        XCTAssertEqual(report.outcome, .completed(.object(["del": .string("undefined"), "list": .string("function")])))
    }

    func testDeniedDestructiveCallRejectsInsideTheScript() async throws {
        let fixture = Fixture()
        let report = try await runtime(fixture).run("""
            try { await tools.deleteExpense({ id: 1 }); return "deleted"; }
            catch (e) { return String(e); }
            """)
        XCTAssertEqual(report.outcome, .completed(.string("denied: the user declined deleteExpense")))
        let deleted = await fixture.deletes.value
        XCTAssertEqual(deleted, 0)
    }

    func testSyntaxErrorsAndThrownErrorsAreReported() async throws {
        let fixture = Fixture()
        let syntax = try await runtime(fixture).run("return {;")
        guard case .scriptFailed(let message) = syntax.outcome else { return XCTFail("\(syntax.outcome)") }
        XCTAssertTrue(message.hasPrefix("syntax error:"), message)
        let thrown = try await runtime(fixture).run(#"throw new Error("plan failed");"#)
        XCTAssertEqual(thrown.outcome, .scriptFailed("uncaught: Error: plan failed"))
    }

    func testAsyncCallLoopIsStoppedByTheBudget() async throws {
        let fixture = Fixture()
        let report = try await runtime(fixture).run(
            #"for (;;) { try { await tools.listExpenses({ month: "2026-11" }); } catch (e) {} }"#,
            budget: ExecutionBudget(maxToolCalls: 6, deadline: .seconds(20))
        )
        XCTAssertEqual(report.outcome, .budgetExhausted)
        XCTAssertEqual(report.executedCalls, 6)
        XCTAssertLessThan(report.elapsed, .seconds(10))
    }

    func testSynchronousCallFloodNeverQueuesMoreThanTheHostLimit() async throws {
        let fixture = Fixture()
        let budget = ExecutionBudget(maxToolCalls: 3, deadline: .seconds(10))
        let report = try await runtime(fixture).run("""
            const pending = [];
            for (let i = 0; i < 100000; i++) pending.push(tools.listExpenses({ month: "2026-11" }).catch(() => 0));
            await Promise.all(pending);
            return pending.length;
            """, budget: budget)
        // The fourth call trips the budget. Past maxHostCalls the engine parks calls on
        // never-settling promises without creating Swift work, so the bridge sees at most that
        // many requests (and the trace never has to drop any), not 100,000.
        let requests = report.trace.events.filter { if case .requested = $0.kind { return true } else { return false } }
        XCTAssertEqual(report.outcome, .budgetExhausted)
        XCTAssertLessThanOrEqual(requests.count, budget.maxHostCalls)
        XCTAssertEqual(report.trace.droppedEvents, 0)
        XCTAssertEqual(report.executedCalls, 3)
    }

    func testEngineHostCallCapIsExactAndEndsTheRun() async throws {
        // The engine on its own, with a host that never refuses, so no bridge timing
        // is involved: 1,000 synchronous calls, cap 10. Exactly 10 may reach Swift,
        // and the run ends with hostCallLimitExceeded instead of completing.
        let reached = Counter()
        let host: ScriptHost = { _ in
            await reached.increment()
            return .success("[]")
        }
        let prelude = try Fixture().registry().prelude(in: CapabilityScope())
        do {
            _ = try await JavaScriptCoreEngine().execute(
                script: """
                const pending = [];
                for (let i = 0; i < 1000; i++) pending.push(tools.listExpenses({ month: "2026-11" }));
                return pending.length;
                """,
                prelude: prelude, limits: EngineLimits(maxHostCalls: 10), host: host)
            XCTFail("the run must end at the cap")
        } catch let error as ScriptError {
            XCTAssertEqual(error, .hostCallLimitExceeded)
        }
        try await Task.sleep(for: .milliseconds(300)) // let any in-flight host tasks land
        let count = await reached.value
        XCTAssertEqual(count, 10)
    }

    func testAwaitingScriptAtTheDeadlineIsReclaimed() async throws {
        let fixture = Fixture()
        let runtime = try runtime(fixture)
        let report = await runtime.run("await tools.gated({}); return 1;", budget: ExecutionBudget(deadline: .milliseconds(100)))
        XCTAssertEqual(report.outcome, .deadlineExceeded)
        XCTAssertEqual(report.orphanedCalls, 1)
        let abandoned = await runtime.abandonedEngines
        XCTAssertEqual(abandoned, 0, "a script parked on await is not stuck and must not count against quarantine")
        await fixture.gate.open()
    }

    func testCatchAndRetryLoopEndsAsABudgetStopAndIsReclaimed() async throws {
        // Every call is refused (invalid arguments), and the plan retries forever.
        // The run must end as a budget stop, and the engine must not be left busy.
        let runtime = try runtime(Fixture())
        let report = await runtime.run(
            "for (;;) { try { await tools.listExpenses({ month: 7 }); } catch (e) {} }",
            budget: ExecutionBudget(maxToolCalls: 5, deadline: .seconds(20))
        )
        XCTAssertEqual(report.outcome, .budgetExhausted)
        XCTAssertLessThan(report.elapsed, .seconds(10))
        let abandoned = await runtime.abandonedEngines
        XCTAssertEqual(abandoned, 0)
    }

    func testParallelPlanReplaysIdentically() async throws {
        let fixture = Fixture()
        let script = """
            const months = ["2026-11", "2026-10", "2026-11"];
            const lists = await Promise.all(months.map(month => tools.listExpenses({ month })));
            return lists.map(l => l.length);
            """
        let report = try await runtime(fixture).run(script)
        XCTAssertEqual(report.outcome, .completed(.array([.number(2), .number(1), .number(2)])))
        let replayer = TraceReplayer(registry: try fixture.registry())
        let verdict = await replayer.replay(script, against: report.trace, engine: JavaScriptCoreEngine()).verdict
        XCTAssertEqual(verdict, .identical(calls: 3, result: .array([.number(2), .number(1), .number(2)])))
        let edited = script.replacingOccurrences(of: #""2026-10", "2026-11""#, with: #""2026-10", "2026-09""#)
        let diverged = await replayer.replay(edited, against: report.trace, engine: JavaScriptCoreEngine()).verdict
        XCTAssertEqual(diverged, .diverged(ordinal: 2, expected: #"listExpenses({"month":"2026-11"})"#, actual: #"listExpenses({"month":"2026-09"})"#))
    }

    func testShortSynchronousStretchAtTheDeadlineIsNotCountedAsAbandoned() async throws {
        // The plan spends most of its time in 30 ms synchronous stretches, so the
        // deadline almost always lands while JavaScript is on the stack. The stretch
        // ends inside the 100 ms cancellation grace, so the engine is reclaimed.
        let runtime = try runtime(Fixture())
        let report = await runtime.run(
            #"for (;;) { await tools.listExpenses({ month: "2026-11" }); const t = Date.now(); while (Date.now() - t < 30) {} }"#,
            budget: ExecutionBudget(maxToolCalls: 10_000, deadline: .milliseconds(400))
        )
        XCTAssertEqual(report.outcome, .deadlineExceeded)
        let abandoned = await runtime.abandonedEngines
        XCTAssertEqual(abandoned, 0)
    }

}

/// Tests that deliberately leave a thread spinning until the process exits (public
/// JavaScriptCore API cannot interrupt a synchronous loop; that is the behaviour
/// under test). Opt-in with `CODEMODE_RUN_SPINNING_TESTS=1`: on GitHub's macos-15
/// runners the test process never exits once these threads are spinning, so CI
/// skips them and they are run locally before each release (see the README).
final class JavaScriptCoreSpinningTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEMODE_RUN_SPINNING_TESTS"] == "1",
                          "set CODEMODE_RUN_SPINNING_TESTS=1 to run tests that leave a thread spinning")
    }

    func runtime(_ fixture: Fixture) throws -> CodeModeRuntime {
        CodeModeRuntime(registry: try fixture.registry(), confirmations: DenyAllConfirmations()) { JavaScriptCoreEngine() }
    }

    func testSynchronousInfiniteLoopHitsTheDeadlineAndIsCountedAsAbandoned() async throws {
        // This deliberately leaves one thread spinning until the test process exits:
        // public JavaScriptCore API cannot interrupt it. That is the behaviour under test.
        let runtime = try runtime(Fixture())
        let report = await runtime.run("while (true) {}", budget: ExecutionBudget(deadline: .milliseconds(200)))
        XCTAssertEqual(report.outcome, .deadlineExceeded)
        XCTAssertLessThan(report.elapsed, .seconds(5))
        let abandoned = await runtime.abandonedEngines
        XCTAssertEqual(abandoned, 1)
    }

    func testScriptThatSettlesAndThenSpinsIsStillCaughtByTheDeadline() async throws {
        // The returned promise settles first; a detached microtask then spins forever
        // on the same thread. Reporting .completed here would leak a busy engine that
        // the quarantine never counts.
        let runtime = try runtime(Fixture())
        // The tool call makes the script resume from a Swift-side resolve, after the
        // engine has attached its .then handlers, so the result really is produced
        // while the spinning microtask is still queued.
        let report = await runtime.run(
            #"await tools.listExpenses({ month: "2026-11" }); (async () => { for (let i = 0; i < 10; i++) await 0; while (true) {} })(); return 1;"#,
            budget: ExecutionBudget(deadline: .milliseconds(500))
        )
        XCTAssertEqual(report.outcome, .deadlineExceeded)
        let abandoned = await runtime.abandonedEngines
        XCTAssertEqual(abandoned, 1)
    }

    func testReplayOfAStuckScriptReportsTheBusyEngine() async throws {
        let replayer = TraceReplayer(registry: try Fixture().registry())
        let result = await replayer.replay("while (true) {}", against: RunTrace(),
                                           budget: ExecutionBudget(deadline: .milliseconds(200)), engine: JavaScriptCoreEngine())
        XCTAssertEqual(result, ReplayResult(verdict: .scriptFailed("replay exceeded the deadline"), engineStillBusy: true))
    }
}
#endif
