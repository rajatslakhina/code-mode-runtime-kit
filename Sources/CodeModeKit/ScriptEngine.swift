import Foundation

public enum ScriptError: Error, Sendable, Equatable {
    /// The script did not compile.
    case syntax(String)
    /// The script threw, or its promise rejected.
    case uncaught(String)
    /// The engine could not start (for example, a context failed to initialise).
    case engineUnavailable(String)
    /// The script made more host calls than `EngineLimits.maxHostCalls`. The engine
    /// ends the run instead of rejecting into the script, so a catch-and-retry loop
    /// cannot turn the cap into a busy microtask loop.
    case hostCallLimitExceeded
}

/// Limits the engine itself enforces, on its side of the bridge.
public struct EngineLimits: Sendable, Equatable {
    /// Host calls accepted before the engine ends the run with
    /// `ScriptError.hostCallLimitExceeded`. Calls past the limit get a promise that
    /// never settles and create no Swift work.
    public let maxHostCalls: Int

    public init(maxHostCalls: Int) { self.maxHostCalls = max(0, maxHostCalls) }
}

/// Runs one script. The runtime creates a fresh engine per run, so an engine that
/// gets stuck (a synchronous infinite loop cannot be pre-empted with public
/// JavaScriptCore API) is abandoned rather than reused.
///
/// Contract:
/// - `prelude` evaluates to a function that takes the host function and returns
///   the `tools` object. The host function must not be reachable any other way.
/// - `script` is the *body* of `async function (tools) { ... }`.
/// - The returned string is the JSON text of the script's final value.
/// - Must return promptly (the JavaScriptCore engine takes at most its 100 ms
///   cancellation grace) by throwing `EngineCancelled` when the calling task is
///   cancelled, even if the script itself is still running, and say whether it was.
///   Any other error thrown after cancellation is treated as `stillBusy: true`.
public protocol ScriptEngine: Sendable {
    func execute(script: String, prelude: String, limits: EngineLimits, host: @escaping ScriptHost) async throws -> String
}

/// Thrown by an engine whose run was cancelled.
public struct EngineCancelled: Error, Sendable, Equatable {
    /// True when the script was executing synchronously at cancellation time, so
    /// the engine's thread may never come back.
    public let stillBusy: Bool
    public init(stillBusy: Bool) { self.stillBusy = stillBusy }
}
