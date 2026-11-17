import Foundation

/// Why a tool call did not produce a result. The message is what the script sees
/// in the rejected promise.
public struct ToolCallFailure: Error, Sendable, Equatable, Codable {
    public enum Code: String, Sendable, Codable, CaseIterable {
        case unknownTool
        case notInScope
        case budgetExhausted
        case invalidArguments
        case denied
        case revoked
        case toolError
        case resultTooLarge
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// One script -> host call, as the engine numbers it. The ordinal is assigned on
/// the JavaScript thread in program order, before any Swift task is created, so
/// it is deterministic even when `Promise.all` makes calls race into the bridge.
public struct HostCall: Sendable, Equatable {
    public let ordinal: Int
    public let tool: String
    public let argumentsJSON: String

    public init(ordinal: Int, tool: String, argumentsJSON: String) {
        self.ordinal = ordinal
        self.tool = tool
        self.argumentsJSON = argumentsJSON
    }
}

public typealias ScriptHost = @Sendable (HostCall) async -> Result<String, ToolCallFailure>

public struct TraceEvent: Sendable, Equatable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        /// `arguments` is canonical JSON when it parsed, the raw text otherwise.
        case requested(tool: String, arguments: String)
        case confirmationRequested
        case confirmationResolved(approved: Bool)
        case succeeded(result: String)
        case failed(ToolCallFailure)
        /// The tool ran but the run had already ended; its result was discarded.
        case lateResultDropped
    }

    /// Bridge-assigned, strictly increasing, gap-free within one run.
    public let sequence: Int
    /// The engine's ordinal for the call this event belongs to.
    public let ordinal: Int
    public let kind: Kind
}

/// Everything a run did, in the order the bridge saw it. Codable, so a run can be
/// stored with a bug report and replayed later without touching real data.
public struct RunTrace: Sendable, Equatable, Codable {
    public internal(set) var events: [TraceEvent] = []
    /// Events not kept because the trace hit its cap.
    public internal(set) var droppedEvents: Int = 0

    public init(events: [TraceEvent] = [], droppedEvents: Int = 0) {
        self.events = events
        self.droppedEvents = droppedEvents
    }

    static func recordedToolName(_ name: String) -> String { String(name.prefix(64)) }
    static func recordedRawArguments(_ text: String) -> String { String(text.prefix(256)) }

    /// How arguments appear in a trace: canonical JSON if they parse within the
    /// limits, otherwise a bounded prefix of the raw text.
    static func recordedArguments(_ text: String, limits: JSONLimits) -> String {
        (try? JSONValue.parse(text, limits: limits))?.canonicalText() ?? recordedRawArguments(text)
    }

    /// Per ordinal: the call as requested and the response the script received.
    /// Calls with no recorded response are left out.
    public var calls: [RecordedCall] {
        var requested: [Int: (tool: String, arguments: String)] = [:]
        var responses: [Int: Result<String, ToolCallFailure>] = [:]
        for event in events {
            switch event.kind {
            case .requested(let tool, let arguments): requested[event.ordinal] = (tool, arguments)
            case .succeeded(let result): responses[event.ordinal] = .success(result)
            case .failed(let failure): responses[event.ordinal] = .failure(failure)
            default: break
            }
        }
        return requested.keys.sorted().compactMap { ordinal in
            guard let request = requested[ordinal], let response = responses[ordinal] else { return nil }
            return RecordedCall(ordinal: ordinal, tool: request.tool, arguments: request.arguments, response: response)
        }
    }
}

public struct RecordedCall: Sendable, Equatable {
    public let ordinal: Int
    public let tool: String
    public let arguments: String
    public let response: Result<String, ToolCallFailure>
}

/// Bounded, sequence-numbering event log. Owned by one actor; not thread-safe on
/// its own.
struct TraceRecorder {
    private(set) var trace = RunTrace()
    private var nextSequence = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    mutating func record(_ ordinal: Int, _ kind: TraceEvent.Kind) {
        guard trace.events.count < capacity else {
            trace.droppedEvents = Saturating.add(trace.droppedEvents, 1)
            return
        }
        trace.events.append(TraceEvent(sequence: nextSequence, ordinal: ordinal, kind: kind))
        nextSequence = Saturating.add(nextSequence, 1)
    }
}
