# CodeModeKit

**Let the model write the program, not make the calls.** CodeModeKit is a Swift runtime for "code mode" in an iOS agent feature. Claude writes one short JavaScript plan. The plan runs in a locked-down JavaScriptCore context, and its only way out is one actor-isolated bridge to your app's typed Swift tools. Every call is checked against a capability scope, a budget and an authorization tier. Destructive calls wait for a human, and every run leaves a trace you can replay.

[![CI](https://github.com/rajatslakhina/code-mode-runtime-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/code-mode-runtime-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6.0-orange) ![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20Linux%20(core)-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-green)

**Demo app:** [code-mode-runtime-demo-app](https://github.com/rajatslakhina/code-mode-runtime-demo-app), a SwiftUI app that runs five plans (parallel review, a delete that has to ask you, an exfiltration attempt, a runaway loop, a write in a read-only run) against this package, consumed from GitHub as a version-pinned remote package.

---

## Why this matters

Classic tool use is one model turn per tool call. The model asks for `listExpenses`, reads the result, asks for the next thing, and so on. Every intermediate result goes back into the context and is read again on every later turn. Eight calls mean nine model turns, and the context grows each time.

Claude Code 2.1.323 (12 November 2026) shipped an experimental **Code Mode**: Claude writes JavaScript that calls its tools, so a loop or a `Promise.all` is one script instead of a dozen turns. The same idea works in an app. It also moves a hard problem onto the client: **you are now executing model-written code on a user's phone.** That is a sandboxing, concurrency, authorization and observability problem, not a prompt problem. This package is one answer to it, with the trade-offs written down.

| Concern | What CodeModeKit does |
|---|---|
| What can the script reach? | Only a frozen `tools` object. No `fetch`, timers, modules or file access; `eval` and the `Function` constructors are disabled; and the host function is never on the global object. |
| What can a tool do? | Whatever its **tier** allows (`read`, `write`, `destructive`). The tier is part of the tool's type. A run's **scope** can narrow it, never widen it. |
| Who approves deletes? | A `ConfirmationProvider` (the demo uses a dialog). Destructive tools always pause, whatever the scope says. |
| What stops a runaway plan? | A call budget enforced on the actor before any suspension point, a host-call cap on the JavaScript side, a wall-clock deadline, and size and depth limits on every JSON crossing. |
| What happens at the deadline? | The bridge is revoked first. Late approvals don't run, late results are dropped, and engines that can't be reclaimed are counted. |
| How do I debug it? | A `RunTrace` with gap-free sequence numbers, keyed by program order. `TraceReplayer` re-runs a script against it without executing a single tool, and stops at the first divergence. |

## Architecture

```
  model-written JS ──► JavaScriptCoreEngine (fresh JSVirtualMachine per run, serial queue)
                          │  prelude: frozen `tools` object → one host function
                          │  ordinals assigned on the JS thread, in program order
                          │  host-call cap (engine side): no Swift work past the cap
                          ▼
                     ToolBridge (actor) ── the only door
                          │  1. revoked?          4. scope / unknown tool
                          │  2. reserve budget    5. parse with limits + schema validation
                          │     (no await yet)    6. confirmation (await) → re-check revoked
                          │  3. tripwire on       7. run tool (await) → drop if revoked
                          │     first overrun     8. result size + output-schema check
                          ▼
                     ToolRegistry ── typed CodeModeTool values (Input: Decodable, Output: Encodable)
                          │
  CodeModeRuntime (actor): admission → race(engine settles, deadline, budget tripwire)
                           → revoke bridge → cancel engine → RunReport { outcome, trace, … }
```

## Usage

```swift
import CodeModeKit

struct ListExpenses: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "listExpenses", summary: "Expenses in a month", tier: .read,
        input: .object([SchemaField("month", .string)]),
        output: .array(.object([SchemaField("id", .integer), SchemaField("cents", .integer)]))
    )
    struct Input: Codable, Sendable { let month: String }
    struct Row: Codable, Sendable { let id: Int; let cents: Int }
    let store: ExpenseStore
    func call(_ input: Input) async throws -> [Row] { await store.rows(in: input.month) }
}

var registry = ToolRegistry()
try registry.register(ListExpenses(store: store))   // throws if the schema disagrees with `Input`

let runtime = CodeModeRuntime(registry: registry, confirmations: MyDialogConfirmations()) {
    JavaScriptCoreEngine()
}

// Put this in the system prompt so the model knows what it can call:
let declarations = await runtime.declarations(in: .readOnly)

// Then run what the model wrote (the body of an async function that receives `tools`):
let report = await runtime.run(modelScript, scope: .readOnly,
                               budget: ExecutionBudget(maxToolCalls: 12, deadline: .seconds(5)))
switch report.outcome {
case .completed(let value):
    reply = value.canonicalText()        // only the final value goes back to the model
case .budgetExhausted, .deadlineExceeded, .scriptFailed, .rejected, .cancelled:
    reply = "plan stopped: \(report.outcome)" // tell the model what happened
}
```

Add it with SwiftPM:

```swift
.package(url: "https://github.com/rajatslakhina/code-mode-runtime-kit.git", from: "1.0.2")
```

## Design decisions and trade-offs

**1. Object-capability sandbox, not a blocklist.** A plain `JSContext` has no network, timers, file system or module loader; those come from browsers and Node, not from the language. So the sandbox question is "what did we hand over?", and the answer is one frozen object. The host function goes to the prelude as an argument and is never a global, so a script that escapes the wrapper function still has nothing to call. A test compares the run's globals with a fresh `JSContext` and fails if the runtime added anything. As defence in depth, `eval` is deleted, and the `Function`, async-function and generator constructors (reachable through any function's `.constructor`) are replaced and locked, so plans can't compile strings at run time. *Rejected:* a WKWebView (it brings `fetch`, a DOM, a separate web-content process and a noticeable start-up cost), and regex-filtering scripts (blocklists lose to obfuscation).

**2. Reserve the budget before the first `await`.** `ToolBridge` is an actor, and actors are re-entrant: at every `await`, another call can enter. If the bridge checked `attempts < max` and only incremented after the tool ran, fifty `Promise.all` calls would all pass the check while the count still read zero. The test suite has a deliberately broken bridge with exactly that bug (`CheckAfterAwaitBridge`) and shows that the concurrency harness catches it: all 50 calls reach the tool instead of 10. Refused calls count too, so a script can't spin on an unknown tool name for free.

**3. Re-check after every suspension point.** A human can take thirty seconds to approve a delete, and the run's deadline can pass in the meantime. After the confirmation returns, the bridge checks `revoked` again, so a late "Approve" never runs the tool. After a tool returns, it checks again, and a late result is recorded as `lateResultDropped` and never reaches the script.

**4. The first call over budget ends the run.** The bridge revokes itself and fires a tripwire. The runtime races three things (the engine settling, the deadline and the tripwire) and stops at the first. Without the tripwire, `for (;;) { try { await tools.x() } catch {} }` would run until the deadline. A script that doesn't catch the refusal fails at the same moment the tripwire fires. The runtime classifies that by cause, so it's reported as `.budgetExhausted`, not as a script failure, whichever wins the race.

**5. Two budget layers, on both sides of the bridge.** `maxToolCalls` is enforced by the actor. But a *synchronous* loop such as `for (let i = 0; i < 1e5; i++) tools.x()` creates a promise, and therefore a Swift `Task`, per call before the actor can say no. So the engine also has a host-call cap (`2 × maxToolCalls + 8`). Past it, a call gets a promise that never settles, no Swift work is created, and the run ends as a budget stop. Parking the call, rather than rejecting it, matters: a synchronous rejection would turn a catch-and-retry loop into a busy microtask loop. A test floods 100,000 calls and checks that the bridge sees no more than the cap.

**6. Honest about what JavaScriptCore can't do.** Public JavaScriptCore API has no execution-time limit; `JSContextGroupSetExecutionTimeLimit` is private SPI, and shipping SPI isn't an option. A synchronous `while (true) {}` can't be interrupted. At the deadline the engine gives JavaScript a 100 ms grace period to leave the stack. If it doesn't, the engine reports `stillBusy: true` and returns, and the spinning thread stays busy until the process exits. The grace costs up to 100 ms at a deadline, and its trade-off is deliberate: without it, a cancellation that happens to land while a promise is being settled would count a healthy engine as abandoned. With it, a script still inside one synchronous stretch longer than 100 ms is counted as abandoned. The count is permanent until the app calls `acknowledgeAbandonedEngines()`, because the runtime can't observe a stuck thread coming back. "Settled" isn't trusted on its own either. If a script's promise resolves during a microtask drain and another microtask then spins, the result is held until JavaScript leaves the stack, which it never does. So the run is reported as `.deadlineExceeded` and counted, not `.completed`. Checking "is the run over?" and marking the queue busy happen under one lock, so a cancellation can't slip into the gap and report an idle engine just before JavaScript starts. The runtime counts such engines, and once `maxUnreclaimedEngines` are in flight or abandoned it **fails closed** and refuses new runs until the app acknowledges the problem. A script that is only *waiting* on a tool at the deadline isn't stuck, and it doesn't count. *Rejected:* reusing one VM across runs (a stuck run would wedge every later one), and a JS interpreter written in Swift (pre-emptible, but slow, and a large surface to get right).

**7. Ordinals come from the JavaScript thread.** Concurrent calls reach the actor in scheduler order, which isn't deterministic. Each call is numbered on the JavaScript thread, in program order, before any Swift task exists. The trace keys calls by that ordinal, so `TraceReplayer` replays a `Promise.all` plan deterministically. It stops at the first divergence and reports whether the replayed engine was left busy. Replays don't share a runtime's quarantine, so they belong in tests and CI, not in an app's request path.

**8. JSON text is the only thing that crosses.** No `JSValue` or Swift object crosses the boundary. Arguments are size-checked and depth-scanned *before* decoding (a linear byte scan, so `[[[[…` bombs never reach a recursive decoder), then validated against the tool's schema, with unknown fields rejected. Results are size-checked and validated against the *declared output schema*, so a buggy tool can't feed the plan a shape it was never promised.

**9. Schemas are checked against the Swift types at registration.** `register` decodes `Input` from two generated examples, one with every optional field and one with none. That catches a field the type needs but the schema lacks or marks optional, and a field with the wrong JSON type. Fields the schema doesn't declare are rejected at call time. The gap is a field the schema declares but the Swift type ignores: validation accepts it and the decoder drops it silently. Keep `Input` and its schema side by side, and review them together.

**10. Errors are model-facing by opt-in.** A tool error reaches the script, and therefore the prompt, only if it conforms to `ModelFacingError`. Anything else becomes "`<tool>` failed", so connection strings and file paths never end up in a model's context by accident.

### What it deliberately does not do

- **Memory limits.** Public JavaScriptCore has no heap cap. Script size, argument size and result size are bounded, but a script can still allocate in a loop until the deadline. Run untrusted plans in an app extension or a separate process if that matters for your threat model.
- **Rollback.** A tool that was already running when the run ended still finishes; Swift can't un-run it. `RunReport.orphanedCalls` says how many. Make destructive tools idempotent, or put them behind confirmation (which is re-checked).
- **Talk to a model.** The runtime executes plans. Prompting, retries and choosing between code mode and classic tool use belong to the caller. `OrchestrationCostModel` helps with that choice.

## The cost model

`OrchestrationCostModel` is a transparent model, not a benchmark. Classic tool use re-reads every earlier result on each turn, and its calls run one after another. In code mode the model reads only the prompt, the script and the final value, and calls run in parallel waves. With the defaults (600-token results, a 2,000-token prompt, eight calls), classic mode reads **41,040** input tokens over **9** turns and code mode reads **4,550** over **2** turns (`CostModelTests.testDefaultWorkloadNumbersQuotedInTheREADME` pins both). The model ignores prompt caching, which narrows the gap, and the cost of retrying a wrong script. Both caveats are in the doc comments and in the demo's chart footer.

## Verification

What was run, and on what:

- **macOS (Xcode 27.2, Swift 6.4.2):** clean `swift build --build-tests -Xswiftc -warnings-as-errors` with **0 warnings**. `swift test` passed **73/73**, including **16 end-to-end tests against real JavaScriptCore**. The 70 tests that run by default passed **5 consecutive runs** on the final source; an earlier revision without the newest test passed 10.
- **Three opt-in tests** deliberately leave a thread spinning (a stuck `while (true) {}`, a script that settles and then spins, and a replay of a stuck script). They run only with `CODEMODE_RUN_SPINNING_TESTS=1`. They pass locally on macOS 27.2, but on GitHub's macos-15 runners the test process never exits once those threads spin, so CI skips them. They were run locally before this release.
- **Linux (Swift 6.0.3):** clean build with warnings as errors. `swift test` passed **57/57** in **25 consecutive runs**. The 16 JavaScriptCore tests are Apple-only; on Linux the runtime, bridge and replayer are covered through a `FakeEngine`.
- **iOS:** `xcodebuild build -scheme CodeModeKit -destination 'generic/platform=iOS Simulator' SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` succeeded.
- **Mutation check:** `scripts/mutation-check.sh` brings back specific bugs one at a time, and each one must make a test fail. Locally, with the spinning tests enabled, **29/29 were caught**. CI runs the **27** mutants that don't depend on the opt-in tests. A mutant that makes the suite hang is killed after 600 s and counted as caught. Run it on macOS, because several mutants live in the JavaScriptCore engine.
- **CI:** the [Actions workflow](https://github.com/rajatslakhina/code-mode-runtime-kit/actions/workflows/ci.yml) runs on pushes to `main`, on tags and on pull requests. It has three jobs: Linux (Swift 6.0, build with warnings as errors, then test); macOS (tests with warnings as errors, then the generic iOS Simulator build); and the 27-mutant check on macOS.
- **Simulator:** the library has no UI. The [demo repo](https://github.com/rajatslakhina/code-mode-runtime-demo-app) says exactly what was run on a Simulator and screenshotted.
- **Review:** three rounds of independent review. Every blocking issue they raised is fixed. The fixes from the last round were checked by the test runs above, not by a fourth review.

## Requirements

iOS 17+ / macOS 14+ for the JavaScriptCore engine. The core (registry, bridge, runtime, replay, cost model) also builds on Linux with Swift 6.0.

## License

MIT
