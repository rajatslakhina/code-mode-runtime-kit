import XCTest
@testable import CodeModeKit

final class SaturatingTests: XCTestCase {
    func testAddAndMultiplySaturateInBothDirections() {
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(.min, -1), .min)
        XCTAssertEqual(Saturating.add(2, 3), 5)
        XCTAssertEqual(Saturating.multiply(.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(.max, -2), .min)
        XCTAssertEqual(Saturating.multiply(.min, -1), .max)
        XCTAssertEqual(Saturating.multiply(-3, 4), -12)
    }

    func testCeilDivideNeverDividesByZero() {
        XCTAssertEqual(Saturating.ceilDivide(7, by: 0), 7)
        XCTAssertEqual(Saturating.ceilDivide(7, by: -3), 7)
        XCTAssertEqual(Saturating.ceilDivide(7, by: 2), 4)
        XCTAssertEqual(Saturating.ceilDivide(8, by: 2), 4)
        XCTAssertEqual(Saturating.ceilDivide(-5, by: 2), 0)
        XCTAssertEqual(Saturating.ceilDivide(.max, by: 1), .max)
    }

    func testTriangular() {
        XCTAssertEqual(Saturating.triangular(0), 0)
        XCTAssertEqual(Saturating.triangular(4), 10)
        XCTAssertEqual(Saturating.triangular(5), 15)
        XCTAssertEqual(Saturating.triangular(-3), 0)
        XCTAssertEqual(Saturating.triangular(.max), .max)
    }
}

final class JSONValueTests: XCTestCase {
    func testDepthBombIsRefusedBeforeDecoding() {
        let bomb = String(repeating: "[", count: 200_000)
        XCTAssertThrowsError(try JSONValue.parse(bomb, limits: JSONLimits(maxBytes: 1_000_000, maxDepth: 32))) {
            XCTAssertEqual($0 as? JSONLimitError, .tooDeep(limit: 32))
        }
    }

    func testBracketsInsideStringsDoNotCountTowardsDepth() throws {
        let text = #"{"note":"[[[[[[[[[[ \" {{{{{{"}"#
        XCTAssertEqual(try JSONValue.parse(text, limits: JSONLimits(maxDepth: 1)), .object(["note": .string("[[[[[[[[[[ \" {{{{{{")]))
    }

    func testDepthExactlyAtTheLimitIsAccepted() throws {
        XCTAssertNoThrow(try JSONValue.parse("[[[1]]]", limits: JSONLimits(maxDepth: 3)))
        XCTAssertThrowsError(try JSONValue.parse("[[[[1]]]]", limits: JSONLimits(maxDepth: 3)))
    }

    func testSizeLimitAndMalformedInput() {
        XCTAssertThrowsError(try JSONValue.parse("\"abcdef\"", limits: JSONLimits(maxBytes: 4))) {
            XCTAssertEqual($0 as? JSONLimitError, .tooLarge(bytes: 8, limit: 4))
        }
        XCTAssertThrowsError(try JSONValue.parse("{oops", limits: JSONLimits())) {
            XCTAssertEqual($0 as? JSONLimitError, .malformed)
        }
    }

    func testCanonicalTextSortsKeysAndWritesNonFiniteAsNull() throws {
        let value = JSONValue.object(["b": .number(1), "a": .array([.bool(true), .null, .number(.nan)])])
        XCTAssertEqual(value.canonicalText(), #"{"a":[true,null,null],"b":1}"#)
        XCTAssertEqual(try JSONValue.parse(value.canonicalText(), limits: JSONLimits()),
                       .object(["a": .array([.bool(true), .null, .null]), "b": .number(1)]))
    }

    func testTopLevelScalarsParse() throws {
        XCTAssertEqual(try JSONValue.parse("42", limits: JSONLimits()), .number(42))
        XCTAssertEqual(try JSONValue.parse("null", limits: JSONLimits()), .null)
        XCTAssertEqual(try JSONValue.parse("false", limits: JSONLimits()), .bool(false))
    }
}

final class SchemaTests: XCTestCase {
    let schema = SchemaType.object([
        SchemaField("id", .integer),
        SchemaField("tags", .array(.string)),
        SchemaField("note", .optional(.string)),
    ])

    func testValidValuePassesIncludingNullAndMissingOptional() {
        XCTAssertEqual(schema.validate(.object(["id": .number(3), "tags": .array([])])), [])
        XCTAssertEqual(schema.validate(.object(["id": .number(3), "tags": .array([]), "note": .null])), [])
    }

    func testUnknownFieldsMissingFieldsAndWrongTypesReportPaths() {
        let issues = schema.validate(.object(["tags": .array([.string("a"), .number(1)]), "extra": .bool(true)]))
        XCTAssertEqual(Set(issues.map(\.description)), [
            "$.extra: unknown field",
            "$.id: missing required field",
            "$.tags[1]: expected string",
        ])
    }

    func testIntegerRejectsFractionsNonFiniteAndUnsafeMagnitudes() {
        XCTAssertFalse(SchemaType.integer.validate(.number(1.5)).isEmpty)
        XCTAssertFalse(SchemaType.integer.validate(.number(.infinity)).isEmpty)
        XCTAssertFalse(SchemaType.integer.validate(.number(1e300)).isEmpty)
        XCTAssertTrue(SchemaType.integer.validate(.number(9_007_199_254_740_992)).isEmpty)
    }

    func testIssueListIsBounded() {
        let huge = JSONValue.array(Array(repeating: .bool(true), count: 10_000))
        XCTAssertEqual(SchemaType.array(.string).validate(huge, limit: 5).count, 5)
    }

    func testTypeScriptSpelling() {
        XCTAssertEqual(schema.typeScript, "{ id: number; tags: Array<string>; note?: string }")
    }
}

final class RegistryTests: XCTestCase {
    func testUnsafeIdentifiersAreRefused() {
        XCTAssertTrue(ToolRegistry.isSafeIdentifier("listExpenses"))
        XCTAssertTrue(ToolRegistry.isSafeIdentifier("_private2"))
        for bad in ["", "1abc", "a-b", "__host", "constructor", "__proto__", "delete", "a b", "café", String(repeating: "a", count: 65)] {
            XCTAssertFalse(ToolRegistry.isSafeIdentifier(bad), bad)
        }
    }

    func testDuplicateAndInvalidNamesThrow() throws {
        let fixture = Fixture()
        var registry = ToolRegistry()
        try registry.register(ListExpensesTool(counter: fixture.expenses))
        XCTAssertThrowsError(try registry.register(ListExpensesTool(counter: fixture.expenses))) {
            XCTAssertEqual($0 as? RegistryError, .duplicate("listExpenses"))
        }
        XCTAssertThrowsError(try registry.register(BadName())) {
            XCTAssertEqual($0 as? RegistryError, .invalidName("__host"))
        }
    }

    struct BadName: CodeModeTool {
        static let descriptor = ToolDescriptor(name: "__host", summary: "", tier: .read, input: .object([]), output: .object([]))
        struct Empty: Codable, Sendable {}
        func call(_ input: Empty) async throws -> Empty { Empty() }
    }

    struct WrongType: CodeModeTool {
        static let descriptor = ToolDescriptor(name: "wrongType", summary: "", tier: .read,
            input: .object([SchemaField("id", .string)]), output: .object([]))
        struct In: Codable, Sendable { let id: Int }
        struct Out: Codable, Sendable {}
        func call(_ input: In) async throws -> Out { Out() }
    }

    struct UndeclaredRequired: CodeModeTool {
        static let descriptor = ToolDescriptor(name: "undeclared", summary: "", tier: .read,
            input: .object([SchemaField("id", .integer)]), output: .object([]))
        struct In: Codable, Sendable { let id: Int; let reason: String }
        struct Out: Codable, Sendable {}
        func call(_ input: In) async throws -> Out { Out() }
    }

    struct OptionalButRequired: CodeModeTool {
        static let descriptor = ToolDescriptor(name: "optionalButRequired", summary: "", tier: .read,
            input: .object([SchemaField("id", .optional(.integer))]), output: .object([]))
        struct In: Codable, Sendable { let id: Int }
        struct Out: Codable, Sendable {}
        func call(_ input: In) async throws -> Out { Out() }
    }

    struct ScalarInput: CodeModeTool {
        static let descriptor = ToolDescriptor(name: "scalar", summary: "", tier: .read, input: .string, output: .object([]))
        struct Out: Codable, Sendable {}
        func call(_ input: String) async throws -> Out { Out() }
    }

    func testSchemaThatDisagreesWithTheSwiftTypeIsRefused() {
        var registry = ToolRegistry()
        for (tool, register) in [
            ("wrongType", { try registry.register(WrongType()) }),
            ("undeclared", { try registry.register(UndeclaredRequired()) }),
            ("optionalButRequired", { try registry.register(OptionalButRequired()) }),
        ] as [(String, () throws -> Void)] {
            XCTAssertThrowsError(try register(), tool) { error in
                guard case .schemaMismatch(let name, _) = error as? RegistryError else { return XCTFail("\(error)") }
                XCTAssertEqual(name, tool)
            }
        }
        XCTAssertThrowsError(try registry.register(ScalarInput())) {
            XCTAssertEqual($0 as? RegistryError, .inputMustBeObject("scalar"))
        }
        XCTAssertTrue(registry.descriptors.isEmpty)
    }

    func testOutOfScopeToolsAreAbsentFromDeclarationsAndPrelude() throws {
        let registry = try Fixture().registry()
        let readOnly = registry.typeScriptDeclarations(in: .readOnly)
        XCTAssertTrue(readOnly.contains("listExpenses(input: { month: string })"))
        XCTAssertFalse(readOnly.contains("deleteExpense"))
        XCTAssertFalse(registry.prelude(in: .readOnly).contains("deleteExpense"))
        let full = registry.typeScriptDeclarations(in: CapabilityScope())
        XCTAssertTrue(full.contains("deleteExpense"))
        XCTAssertTrue(full.contains("[destructive] Pauses for user confirmation."))
    }

    func testDestructiveAlwaysConfirmsWhateverTheScopeSays() {
        let lax = CapabilityScope(confirmAtOrAbove: .destructive)
        XCTAssertTrue(lax.needsConfirmation(DeleteExpenseTool.descriptor))
        XCTAssertFalse(lax.needsConfirmation(ListExpensesTool.descriptor))
        let strict = CapabilityScope(confirmAtOrAbove: .read)
        XCTAssertTrue(strict.needsConfirmation(ListExpensesTool.descriptor))
    }

    func testBudgetClampsHostileValues() {
        let budget = ExecutionBudget(maxToolCalls: -5, deadline: .seconds(-1), maxScriptBytes: -1)
        XCTAssertEqual(budget.maxToolCalls, 0)
        XCTAssertEqual(budget.deadline, .milliseconds(1))
        XCTAssertEqual(budget.maxScriptBytes, 0)
        XCTAssertEqual(ExecutionBudget(maxToolCalls: .max).maxToolCalls, 10_000)
        XCTAssertEqual(ExecutionBudget(deadline: .seconds(100_000)).deadline, .seconds(600))
    }

    func testTraceRecorderIsBounded() {
        var recorder = TraceRecorder(capacity: 2)
        for i in 0..<5 { recorder.record(i, .confirmationRequested) }
        XCTAssertEqual(recorder.trace.events.map(\.sequence), [0, 1])
        XCTAssertEqual(recorder.trace.droppedEvents, 3)
    }
}

final class CostModelTests: XCTestCase {
    let workload = OrchestrationCostModel.Workload(
        toolCalls: 2, resultTokensPerCall: 100, callTokensPerCall: 10, promptTokens: 1_000,
        scriptTokens: 300, finalValueTokens: 20, answerTokens: 50,
        modelTurnMilliseconds: 1_000, toolMilliseconds: 100, parallelism: 4
    )

    func testClassicMatchesHandComputedValues() {
        // 3 turns re-read the prompt (3 x 1000); turns 2 and 3 re-read 1 and 2 call/result pairs (110 x 3).
        XCTAssertEqual(OrchestrationCostModel().classic(workload),
                       .init(modelTurns: 3, inputTokens: 3_330, outputTokens: 70, latencyMilliseconds: 3_200))
    }

    func testCodeModeMatchesHandComputedValues() {
        // Turn 1: prompt. Turn 2: prompt + script + final value. One wave of parallel calls.
        XCTAssertEqual(OrchestrationCostModel().codeMode(workload),
                       .init(modelTurns: 2, inputTokens: 2_320, outputTokens: 350, latencyMilliseconds: 2_100))
    }

    func testBreakEvenIsWhereCodeModeFirstReadsLess() {
        XCTAssertEqual(OrchestrationCostModel().inputBreakEven(workload), 2)
        var tiny = workload
        tiny.resultTokensPerCall = 0
        tiny.callTokensPerCall = 0
        tiny.scriptTokens = 100_000
        XCTAssertNil(OrchestrationCostModel().inputBreakEven(tiny, upTo: 10))
    }

    func testDefaultWorkloadNumbersQuotedInTheREADME() {
        let defaults = OrchestrationCostModel.Workload()
        // 9 prompts x 2000 + 640 x (1 + ... + 8) = 18,000 + 23,040.
        XCTAssertEqual(OrchestrationCostModel().classic(defaults).inputTokens, 41_040)
        XCTAssertEqual(OrchestrationCostModel().classic(defaults).modelTurns, 9)
        XCTAssertEqual(OrchestrationCostModel().codeMode(defaults).inputTokens, 4_550)
    }

    func testExtremeInputsSaturateInsteadOfTrapping() {
        var extreme = workload
        extreme.toolCalls = .max
        extreme.resultTokensPerCall = .max
        extreme.parallelism = 0
        extreme.toolMilliseconds = .max
        let classic = OrchestrationCostModel().classic(extreme)
        let code = OrchestrationCostModel().codeMode(extreme)
        XCTAssertEqual(classic.inputTokens, .max)
        XCTAssertEqual(classic.latencyMilliseconds, .max)
        XCTAssertEqual(code.latencyMilliseconds, .max)
        XCTAssertEqual(code.modelTurns, 2)
    }
}
