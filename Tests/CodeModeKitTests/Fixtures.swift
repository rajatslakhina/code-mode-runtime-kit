import Foundation
@testable import CodeModeKit

// MARK: - Shared test state

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Holds every caller of `wait()` until `open()`. Used to keep many tool calls
/// in flight at once, so budget checks are exercised under real interleaving.
actor Gate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// Waits (polling) until `condition` holds or two seconds pass.
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<400 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Tools

struct MonthInput: Codable, Sendable { let month: String }
struct Expense: Codable, Sendable, Equatable { let id: Int; let merchant: String; let cents: Int }

struct ListExpensesTool: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "listExpenses", summary: "Expenses for a month", tier: .read,
        input: .object([SchemaField("month", .string)]),
        output: .array(.object([SchemaField("id", .integer), SchemaField("merchant", .string), SchemaField("cents", .integer)]))
    )
    let counter: Counter
    func call(_ input: MonthInput) async throws -> [Expense] {
        await counter.increment()
        return input.month == "2026-11"
            ? [Expense(id: 1, merchant: "Cafe", cents: 450), Expense(id: 2, merchant: "Books", cents: 2_000)]
            : [Expense(id: 3, merchant: "Rail", cents: 1_200)]
    }
}

struct IDInput: Codable, Sendable { let id: Int }
struct Ack: Codable, Sendable { let ok: Bool }

struct DeleteExpenseTool: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "deleteExpense", summary: "Deletes an expense", tier: .destructive,
        input: .object([SchemaField("id", .integer)]), output: .object([SchemaField("ok", .boolean)])
    )
    let counter: Counter
    func call(_ input: IDInput) async throws -> Ack {
        await counter.increment()
        return Ack(ok: true)
    }
}

struct GatedTool: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "gated", summary: "Waits on a gate", tier: .read,
        input: .object([]), output: .object([SchemaField("ok", .boolean)])
    )
    let gate: Gate
    let counter: Counter
    struct Empty: Codable, Sendable {}
    func call(_ input: Empty) async throws -> Ack {
        await counter.increment()
        await gate.wait()
        return Ack(ok: true)
    }
}

struct SafeError: ModelFacingError { var modelFacingMessage: String { "card declined" } }
struct SecretError: Error { let detail = "postgres://admin:hunter2@db" }

struct FailingTool: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "failing", summary: "Always throws", tier: .read,
        input: .object([SchemaField("safe", .boolean)]), output: .object([])
    )
    struct In: Codable, Sendable { let safe: Bool }
    struct Out: Codable, Sendable {}
    func call(_ input: In) async throws -> Out {
        if input.safe { throw SafeError() }
        throw SecretError()
    }
}

struct BigResultTool: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "big", summary: "Returns a large string", tier: .read,
        input: .object([SchemaField("bytes", .integer)]), output: .object([SchemaField("text", .string)])
    )
    struct In: Codable, Sendable { let bytes: Int }
    struct Out: Codable, Sendable { let text: String }
    func call(_ input: In) async throws -> Out { Out(text: String(repeating: "x", count: max(0, min(input.bytes, 1_000_000)))) }
}

/// Declares an integer output but returns a string: a buggy tool.
struct LyingTool: CodeModeTool {
    static let descriptor = ToolDescriptor(
        name: "lying", summary: "Output does not match its schema", tier: .read,
        input: .object([]), output: .object([SchemaField("count", .integer)])
    )
    struct In: Codable, Sendable {}
    struct Out: Codable, Sendable { let count: String }
    func call(_ input: In) async throws -> Out { Out(count: "seven") }
}

struct Fixture {
    let expenses = Counter()
    let deletes = Counter()
    let gated = Counter()
    let gate = Gate()

    func registry() throws -> ToolRegistry {
        var registry = ToolRegistry()
        try registry.register(ListExpensesTool(counter: expenses))
        try registry.register(DeleteExpenseTool(counter: deletes))
        try registry.register(GatedTool(gate: gate, counter: gated))
        try registry.register(FailingTool())
        try registry.register(BigResultTool())
        try registry.register(LyingTool())
        return registry
    }
}

// MARK: - Confirmation providers

/// Parks each confirmation until the test answers it.
actor ParkedConfirmations: ConfirmationProvider {
    private var parked: [CheckedContinuation<ConfirmationDecision, Never>] = []
    private(set) var asked = 0

    nonisolated func confirm(_ request: ConfirmationRequest) async -> ConfirmationDecision {
        await park()
    }

    private func park() async -> ConfirmationDecision {
        asked += 1
        return await withCheckedContinuation { parked.append($0) }
    }

    func answerAll(_ decision: ConfirmationDecision) {
        let pending = parked
        parked = []
        pending.forEach { $0.resume(returning: decision) }
    }
}

// MARK: - Engines

/// Numbers calls in the order the body makes them, like the JS engine does.
final class OrdinalSource: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    func take() -> Int {
        lock.lock(); defer { lock.unlock() }
        let value = next
        next += 1
        return value
    }
}

typealias FakeCall = @Sendable (_ tool: String, _ arguments: JSONValue) async -> Result<JSONValue, ToolCallFailure>

/// A `ScriptEngine` whose "script" is a Swift closure. Lets the runtime and bridge
/// be tested on Linux, where JavaScriptCore does not exist.
struct FakeEngine: ScriptEngine {
    let body: @Sendable (_ call: @escaping FakeCall) async throws -> JSONValue

    func execute(script: String, prelude: String, limits: EngineLimits, host: @escaping ScriptHost) async throws -> String {
        let ordinals = OrdinalSource()
        do {
            let value = try await body { tool, arguments in
                let call = HostCall(ordinal: ordinals.take(), tool: tool, argumentsJSON: arguments.canonicalText())
                switch await host(call) {
                case .success(let text):
                    return (try? JSONValue.parse(text, limits: JSONLimits())).map { .success($0) } ?? .failure(ToolCallFailure(.toolError, "bad json"))
                case .failure(let failure):
                    return .failure(failure)
                }
            }
            return value.canonicalText()
        } catch {
            // Honour the engine contract: after cancellation, report "not busy" (a
            // Swift closure always yields at its awaits). Before it, rethrow.
            if error is CancellationError || Task.isCancelled { throw EngineCancelled(stillBusy: false) }
            throw error
        }
    }
}

/// Never finishes, like a JS engine stuck in `while (true) {}`, and reports itself
/// busy when cancelled.
struct StuckEngine: ScriptEngine {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var continuation: CheckedContinuation<String, Error>?
        var cancelled = false
    }

    func execute(script: String, prelude: String, limits: EngineLimits, host: @escaping ScriptHost) async throws -> String {
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.lock.lock()
                if box.cancelled {
                    box.lock.unlock()
                    continuation.resume(throwing: EngineCancelled(stillBusy: true))
                } else {
                    box.continuation = continuation
                    box.lock.unlock()
                }
            }
        } onCancel: {
            box.lock.lock()
            let pending = box.continuation
            box.continuation = nil
            box.cancelled = true
            box.lock.unlock()
            pending?.resume(throwing: EngineCancelled(stillBusy: true))
        }
    }
}

/// Counts how many engines the runtime created.
final class EngineCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
