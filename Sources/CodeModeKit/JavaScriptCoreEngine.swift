#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore

/// A `ScriptEngine` backed by a fresh `JSVirtualMachine` per run.
///
/// **Why the sandbox holds.** A plain `JSContext` has no `fetch`, no
/// `XMLHttpRequest`, no timers, no `require`, no file system and no module loader:
/// those are browser and Node features, not language features. The only authority
/// a script receives is the frozen `tools` object built by the prelude, and every
/// method on it funnels into one host function that is passed to the prelude as an
/// argument and never placed on the global object. This is object-capability
/// security: the question is not "what did we block?" but "what did we hand over?".
/// `eval` is removed as well, as defence in depth against obfuscated plans.
///
/// **What it cannot do.** Public JavaScriptCore API has no execution-time limit
/// (`JSContextGroupSetExecutionTimeLimit` is private SPI). A synchronous infinite
/// loop therefore cannot be interrupted. On cancellation the engine returns within
/// `cancellationGrace` (100 ms): `stillBusy: false` if JavaScript left the stack in
/// that time, `stillBusy: true` otherwise. A stuck loop keeps one thread busy until
/// the process exits, and the runtime counts it against `maxUnreclaimedEngines`.
public struct JavaScriptCoreEngine: ScriptEngine {
    public init() {}

    public func execute(script: String, prelude: String, limits: EngineLimits, host: @escaping ScriptHost) async throws -> String {
        let session = JSCSession(host: host, limits: limits)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(script: script, prelude: prelude, continuation: continuation)
            }
        } onCancel: {
            session.cancel()
        }
    }
}

/// One run's JavaScript state.
///
/// `@unchecked Sendable` is justified by confinement: every `JSContext` and
/// `JSValue` touch happens on `queue`, a private serial queue. The only state read
/// from other threads is `continuation`/`finished`/`busy`/`cancelPending`, guarded by
/// `lock`. The lock is never held while calling into JavaScript, so `cancel()` can
/// always complete even while `queue` is stuck in a script's infinite loop.
final class JSCSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodeModeKit.JavaScriptCoreEngine")
    private let lock = NSLock()
    private let host: ScriptHost
    private let limits: EngineLimits

    // Guarded by `lock`.
    private var continuation: CheckedContinuation<String, Error>?
    private var finished = false
    private var busy = false
    /// Set when a cancellation found JavaScript on the stack and is waiting out the
    /// grace period to see whether it leaves.
    private var cancelPending = false

    /// How long a cancellation waits for a synchronous slice of JavaScript to finish
    /// before declaring the engine stuck. Without it, a cancellation that lands while
    /// a promise is merely being settled would count a healthy engine as abandoned.
    static let cancellationGrace: DispatchTimeInterval = .milliseconds(100)

    // Confined to `queue`.
    private var context: JSContext?
    /// Nesting depth of synchronous JavaScript entry points currently on the stack.
    private var depth = 0
    /// A result produced while JavaScript was still on the stack (for example the
    /// script's promise settling during a microtask drain). Delivered only once the
    /// outermost entry point returns, so a script that settles and then keeps
    /// spinning in another microtask is still running, still busy, and still caught
    /// by the deadline.
    private var deferred: Result<String, Error>?
    private var hostCalls = 0
    /// Pending promise settlers, keyed by host-call ordinal. At most maxHostCalls.
    private var settles: [Int: (resolve: JSValue?, reject: JSValue?)] = [:]
    private var pendingException: String?

    init(host: @escaping ScriptHost, limits: EngineLimits) {
        self.host = host
        self.limits = limits
    }

    func start(script: String, prelude: String, continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        let alreadyCancelled = finished
        if !alreadyCancelled { self.continuation = continuation }
        lock.unlock()
        if alreadyCancelled {
            continuation.resume(throwing: EngineCancelled(stillBusy: false))
            return
        }
        queue.async { [self] in self.run(script: script, prelude: prelude) }
    }

    func cancel() {
        lock.lock()
        finished = true
        guard busy else {
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(throwing: EngineCancelled(stillBusy: false))
            return
        }
        // JavaScript is on the stack. If it leaves within the grace period,
        // clearBusy() resumes with stillBusy: false; otherwise the timer below
        // declares the engine stuck. Either way this returns promptly and never
        // waits on `queue`, which may never come back.
        cancelPending = true
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancellationGrace) { [self] in
            self.lock.lock()
            let pending = self.continuation
            self.continuation = nil
            self.lock.unlock()
            pending?.resume(throwing: EngineCancelled(stillBusy: true))
        }
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    /// Atomically: refuse if the run is over, otherwise mark the queue busy. Checking
    /// `finished` and setting `busy` under one lock closes the window in which a
    /// cancellation could see "not busy" just before JavaScript starts running.
    private func tryMarkBusy() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        busy = true
        return true
    }

    private func clearBusy() {
        lock.lock()
        busy = false
        let pending = cancelPending ? continuation : nil
        if cancelPending { continuation = nil }
        lock.unlock()
        pending?.resume(throwing: EngineCancelled(stillBusy: false))
    }

    /// Records the run's result. Queue-confined.
    private func finish(_ result: Result<String, Error>) {
        if depth > 0 {
            if deferred == nil { deferred = result }
            return
        }
        deliver(result)
    }

    private func deliver(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        finished = true
        lock.unlock()
        pending?.resume(with: result)
        // finish() can run inside a JavaScript callback; release the context on a
        // later turn of the queue, never while JavaScript is still on the stack.
        queue.async { [self] in
            self.settles.removeAll()
            self.context = nil
        }
    }

    /// Runs a synchronous JavaScript entry point with the busy flag set, so a
    /// cancellation that lands meanwhile knows the queue may never come back.
    /// Does nothing (and returns false) if the run is already over.
    @discardableResult
    private func entering(_ body: () -> Void) -> Bool {
        if depth == 0 {
            guard tryMarkBusy() else { return false }
        }
        depth += 1
        body()
        depth -= 1
        if depth == 0 {
            clearBusy()
            if let result = deferred {
                deferred = nil
                deliver(result)
            }
        }
        return true
    }

    // MARK: - Queue-confined

    private func run(script: String, prelude: String) {
        guard !isFinished else { return }
        guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            finish(.failure(ScriptError.engineUnavailable("could not create a JSContext")))
            return
        }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in
            self?.pendingException = exception?.toString() ?? "unknown exception"
        }
        context.globalObject.deleteProperty("eval")

        let hostFunction: @convention(block) (String, String) -> JSValue? = { [weak self] tool, arguments in
            self?.handleHostCall(tool: tool, arguments: arguments)
        }
        let onFulfilled: @convention(block) (JSValue?) -> Void = { [weak self] value in
            self?.finish(.success(value?.toString() ?? "null"))
        }
        let onRejected: @convention(block) (JSValue?) -> Void = { [weak self] reason in
            self?.finish(.failure(ScriptError.uncaught(reason?.toString() ?? "rejected")))
        }

        // The user script is the body of an async function. Its value is serialised
        // inside JavaScript, so only text ever crosses back.
        let wrapped = """
        (async function (tools) {
          const __result = await (async function (tools) {
            "use strict";
        \(script)
          })(tools);
          const __text = JSON.stringify(__result === undefined ? null : __result);
          return __text === undefined ? "null" : __text;
        })
        """

        entering {
            // Defence in depth: remove every way to compile a string at run time.
            // `eval` is gone above; the Function constructors are reachable through
            // any function's `.constructor`, so they are replaced and locked.
            _ = context.evaluateScript(Self.hardening)
            guard takeException() == nil else {
                finish(.failure(ScriptError.engineUnavailable("hardening failed")))
                return
            }
            guard let makeTools = context.evaluateScript(prelude), takeException() == nil,
                  let hostValue = JSValue(object: hostFunction, in: context),
                  let tools = makeTools.call(withArguments: [hostValue]), takeException() == nil else {
                finish(.failure(ScriptError.engineUnavailable("prelude failed")))
                return
            }
            guard let main = context.evaluateScript(wrapped) else {
                finish(.failure(ScriptError.syntax("could not evaluate script")))
                return
            }
            if let message = takeException() {
                finish(.failure(ScriptError.syntax(message)))
                return
            }
            // A synchronous infinite loop in the script blocks right here.
            guard let promise = main.call(withArguments: [tools]), takeException() == nil,
                  let fulfilled = JSValue(object: onFulfilled, in: context),
                  let rejected = JSValue(object: onRejected, in: context) else {
                finish(.failure(ScriptError.uncaught("script did not start")))
                return
            }
            promise.invokeMethod("then", withArguments: [fulfilled, rejected])
        }
    }

    static let hardening = """
    (function () {
      "use strict";
      const blocked = function () { throw new TypeError("dynamic code is disabled"); };
      const prototypes = [
        Function.prototype,
        Object.getPrototypeOf(async function () {}),
        Object.getPrototypeOf(function* () {}),
        Object.getPrototypeOf(async function* () {}),
      ];
      for (const proto of prototypes) {
        Object.defineProperty(proto, "constructor", { value: blocked, writable: false, configurable: false });
      }
      delete globalThis.Function;
    })();
    """

    private func takeException() -> String? {
        defer { pendingException = nil }
        return pendingException
    }

    /// Called by JavaScript, on `queue`. Returns a promise; the Swift work behind it
    /// happens off the queue and settles the promise back on the queue.
    private func handleHostCall(tool: String, arguments: String) -> JSValue? {
        guard let context = JSContext.current() else { return nil }
        let ordinal = hostCalls
        hostCalls = Saturating.add(hostCalls, 1)
        // Engine-side limit: past it, no Swift task is created at all, so a
        // synchronous call loop cannot queue unbounded work.
        let overLimit = ordinal >= limits.maxHostCalls || isFinished
        if ordinal == limits.maxHostCalls {
            // First call past the cap ends the run (delivered once JavaScript leaves
            // the stack; if it never does, the deadline catches it as busy).
            finish(.failure(ScriptError.hostCallLimitExceeded))
        }
        return JSValue(newPromiseIn: context) { [weak self] resolve, reject in
            guard let self else { return }
            // Past the cap (or after the run): a promise that never settles. No Swift
            // work is created, and nothing wakes the script up to try again.
            if overLimit { return }
            // The resolve/reject functions stay on the queue, keyed by ordinal. The
            // Swift task carries only the ordinal and the result, so no JSValue is
            // ever retained or released off the queue (releasing one takes the VM
            // lock, which a stuck script holds forever).
            self.settles[ordinal] = (resolve, reject)
            let call = HostCall(ordinal: ordinal, tool: tool, argumentsJSON: arguments)
            let host = self.host
            Task { [weak self] in
                let result = await host(call)
                self?.queue.async { [weak self] in
                    guard let self, let settle = self.settles.removeValue(forKey: ordinal) else { return }
                    self.entering {
                        switch result {
                        case .success(let text): _ = settle.resolve?.call(withArguments: [text])
                        case .failure(let failure): _ = settle.reject?.call(withArguments: ["\(failure.code.rawValue): \(failure.message)"])
                        }
                    }
                }
            }
        }
    }
}

#endif
