import Foundation

/// A transparent model of what "code mode" changes, not a measurement.
///
/// **Classic tool use**: the model emits one tool call per turn, sees the result,
/// and decides the next call. Every tool result is appended to the conversation and
/// re-read on every later turn, and calls run one after another.
///
/// **Code mode**: the model writes one script, the runtime executes it (calls can
/// run in parallel), and only the script's final value returns to the model, which
/// then writes the answer. Intermediate results never enter the context.
///
/// The model ignores prompt caching (which cuts the cost of re-read context in
/// classic mode) and the chance that a script is wrong and needs a second attempt.
/// Both are stated in the README and in the demo app's chart footer, because a cost
/// model that hides its assumptions is a sales pitch.
public struct OrchestrationCostModel: Sendable, Equatable {
    public struct Workload: Sendable, Equatable {
        public var toolCalls: Int
        public var resultTokensPerCall: Int
        public var callTokensPerCall: Int
        public var promptTokens: Int
        public var scriptTokens: Int
        public var finalValueTokens: Int
        public var answerTokens: Int
        public var modelTurnMilliseconds: Int
        public var toolMilliseconds: Int
        /// How many calls a script runs at once (`Promise.all` width).
        public var parallelism: Int

        public init(
            toolCalls: Int = 8, resultTokensPerCall: Int = 600, callTokensPerCall: Int = 40,
            promptTokens: Int = 2_000, scriptTokens: Int = 350, finalValueTokens: Int = 200,
            answerTokens: Int = 250, modelTurnMilliseconds: Int = 1_200, toolMilliseconds: Int = 80,
            parallelism: Int = 4
        ) {
            self.toolCalls = toolCalls
            self.resultTokensPerCall = resultTokensPerCall
            self.callTokensPerCall = callTokensPerCall
            self.promptTokens = promptTokens
            self.scriptTokens = scriptTokens
            self.finalValueTokens = finalValueTokens
            self.answerTokens = answerTokens
            self.modelTurnMilliseconds = modelTurnMilliseconds
            self.toolMilliseconds = toolMilliseconds
            self.parallelism = parallelism
        }
    }

    public struct Estimate: Sendable, Equatable {
        public let modelTurns: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let latencyMilliseconds: Int
    }

    public init() {}

    public func classic(_ w: Workload) -> Estimate {
        let calls = max(0, w.toolCalls)
        let perCall = Saturating.add(max(0, w.resultTokensPerCall), max(0, w.callTokensPerCall))
        // Turn k (0...calls) re-reads the prompt plus k earlier call/result pairs.
        let prompts = Saturating.multiply(Saturating.add(calls, 1), max(0, w.promptTokens))
        let history = Saturating.multiply(perCall, Saturating.triangular(calls))
        let output = Saturating.add(Saturating.multiply(calls, max(0, w.callTokensPerCall)), max(0, w.answerTokens))
        let turns = Saturating.add(calls, 1)
        let latency = Saturating.add(
            Saturating.multiply(turns, max(0, w.modelTurnMilliseconds)),
            Saturating.multiply(calls, max(0, w.toolMilliseconds))
        )
        return Estimate(modelTurns: turns, inputTokens: Saturating.add(prompts, history), outputTokens: output, latencyMilliseconds: latency)
    }

    public func codeMode(_ w: Workload) -> Estimate {
        let calls = max(0, w.toolCalls)
        let prompt = max(0, w.promptTokens)
        // Turn 1 reads the prompt and writes the script; turn 2 reads prompt, script
        // and the final value, and writes the answer.
        let secondTurn = Saturating.add(Saturating.add(prompt, max(0, w.scriptTokens)), max(0, w.finalValueTokens))
        let input = Saturating.add(prompt, secondTurn)
        let output = Saturating.add(max(0, w.scriptTokens), max(0, w.answerTokens))
        let waves = Saturating.ceilDivide(calls, by: w.parallelism)
        let latency = Saturating.add(
            Saturating.multiply(2, max(0, w.modelTurnMilliseconds)),
            Saturating.multiply(waves, max(0, w.toolMilliseconds))
        )
        return Estimate(modelTurns: 2, inputTokens: input, outputTokens: output, latencyMilliseconds: latency)
    }

    /// Smallest call count at which code mode reads fewer input tokens than classic
    /// tool use, searching 0...limit. `nil` if it never does in that range.
    public func inputBreakEven(_ w: Workload, upTo limit: Int = 64) -> Int? {
        var workload = w
        for calls in 0...min(max(0, limit), 10_000) {
            workload.toolCalls = calls
            if codeMode(workload).inputTokens < classic(workload).inputTokens { return calls }
        }
        return nil
    }
}
