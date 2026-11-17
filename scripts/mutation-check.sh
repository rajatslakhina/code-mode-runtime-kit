#!/usr/bin/env bash
# Each mutant re-introduces a specific bug the README claims the design prevents.
# A mutant "survives" if the test suite still passes with it applied: that means the
# claim is untested. The script fails if any mutant survives, if a mutant does not
# compile, if a pattern is not found exactly once, or if the unmutated suite fails.
#
# Run on macOS: several mutants live in the JavaScriptCore engine, which does not
# exist on Linux (a Linux run would report them as survivors, correctly).
set -u
cd "$(dirname "$0")/.."
S=Sources/CodeModeKit
# file | exact text to replace (must occur exactly once) | replacement | the claim it breaks
MUTANTS=(
  "$S/ToolBridge.swift|guard attempts < budget.maxToolCalls else {|guard true else {|the tool-call budget is enforced"
  "$S/ToolBridge.swift|            tripwire?.yield(.budgetExhausted)|            _ = tripwire|the first over-budget call stops the run, not the deadline"
  "$S/ToolBridge.swift|guard scope.allows(descriptor) else {|guard true else {|the bridge re-checks scope even if a script reaches the host directly"
  "$S/ToolBridge.swift|guard issues.isEmpty else {|guard true else {|arguments are validated against the schema before a tool sees them"
  "$S/ToolBridge.swift|            guard !revoked else { return refuse(.revoked, \"the run ended before confirmation arrived\") }|            // (re-check removed)|an approval that arrives after the run ended never runs the tool"
  "$S/ToolBridge.swift|guard decision == .approved else {|guard true else {|a denied confirmation never runs the tool"
  "$S/ToolBridge.swift|        guard !revoked else {
            recorder.record(ordinal, .lateResultDropped)|        guard false else {
            recorder.record(ordinal, .lateResultDropped)|a result that arrives after the run ended is dropped"
  "$S/ToolBridge.swift|guard data.count <= budget.resultLimits.maxBytes else {|guard true else {|oversized tool results are refused with a reason"
  "$S/ToolBridge.swift|descriptor.output.validate(value).isEmpty else {|true else {|tool output is checked against its declared schema"
  "$S/ToolBridge.swift|(error as? ModelFacingError)?.modelFacingMessage ?? \"\\(descriptor.name) failed\"|\"\\(error)\"|internal error details never reach the script"
  "$S/Policy.swift|        tool.tier >= confirmAtOrAbove|        tool.tier > confirmAtOrAbove|destructive tools always pause for confirmation"
  "$S/Schema.swift|for key in members.keys.sorted() where !declared.contains(key) {|for key in members.keys.sorted() where false {|unknown argument fields are refused"
  "$S/JSONValue.swift|guard nestingDepth(of: data, stopAbove: limits.maxDepth) <= limits.maxDepth else {|guard true else {|nesting bombs are refused before decoding"
  "$S/JSONValue.swift|guard data.count <= limits.maxBytes else {|guard true else {|oversized JSON is refused before decoding"
  "$S/ToolRegistry.swift|for includeOptionals in [true, false] {|for includeOptionals in [Bool]() {|a schema that disagrees with its Swift type is refused at registration"
  "$S/ToolRegistry.swift|!name.hasPrefix(\"__\"),|true,|tool names cannot collide with internal __ names"
  "$S/JavaScriptCoreEngine.swift|        let pending = cancelPending ? continuation : nil|        let pending: CheckedContinuation<String, Error>? = nil|a healthy engine mid-slice at the deadline is reclaimed within the grace period"
  "$S/CodeModeRuntime.swift|guard Saturating.add(inFlight, abandoned) < maxUnreclaimedEngines else {|guard abandoned < maxUnreclaimedEngines else {|concurrent runs cannot slip past admission"
  "$S/CodeModeRuntime.swift|if engineBusy { abandoned = Saturating.add(abandoned, 1) }|abandoned = Saturating.add(abandoned, 1)|only engines that were still running count against quarantine"
  "$S/JavaScriptCoreEngine.swift|let overLimit = ordinal >= limits.maxHostCalls \|\| isFinished|let overLimit = isFinished|a synchronous call flood never queues more than maxHostCalls Swift tasks"
  "$S/JavaScriptCoreEngine.swift|        context.globalObject.deleteProperty(\"eval\")|        // eval kept|eval is removed from the context"
  "$S/JavaScriptCoreEngine.swift|        busy = true|        busy = false|a script stuck in a synchronous loop is reported busy and counted"
  "$S/JavaScriptCoreEngine.swift|        if depth > 0 {|        if false {|a script that settles and then keeps spinning is not reported as completed"
  "$S/JavaScriptCoreEngine.swift|        Object.defineProperty(proto, \"constructor\", { value: blocked, writable: false, configurable: false });|        // constructors left alone|the Function constructors cannot compile strings"
  "$S/CodeModeRuntime.swift|        case .settled where exhausted, .settled(.failure(.hostCallLimitExceeded)):|        case .settled(.failure(.hostCallLimitExceeded)):|a refused-for-budget run is a budget stop whether or not the script caught the refusal"
  "$S/TraceReplayer.swift|        onDivergence.yield()|        _ = onDivergence|a diverged replay stops instead of looping until the deadline"
  "$S/TraceReplayer.swift|guard expected.tool == tool, expected.arguments == arguments else {|guard expected.tool == tool else {|replay detects changed arguments"
  "$S/TraceReplayer.swift|if let missing = await ledger.firstUnanswered, outcome != nil {|if false, let missing = await ledger.firstUnanswered, outcome != nil {|replay detects a skipped call"
  "$S/Saturating.swift|        return b > 0 ? .max : .min|        return result|counts saturate instead of wrapping"
)
# A mutant that makes a test hang (killed after 600 s) counts as caught, not as a
# stuck job. The README says so.
# macOS has no `timeout`; perl's alarm is a portable fallback.
if command -v timeout >/dev/null; then LIMIT="timeout 600"; else LIMIT="perl -e alarm(600);exec(@ARGV)"; fi
if ! swift build --build-tests -q >/dev/null 2>&1 || ! $LIMIT swift test --skip-build >/dev/null 2>&1; then
  echo "BASELINE FAILED: the unmutated suite must pass before mutants mean anything"; exit 2
fi
echo "baseline: unmutated suite passes"
survived=0; caught=0
# Originals are kept outside Sources/ (SwiftPM would warn about stray files) and restored on any exit.
BACKUP=$(mktemp -d); CURRENT=""
trap '[ -n "$CURRENT" ] && cp "$BACKUP/orig" "$CURRENT"; rm -rf "$BACKUP"' EXIT
for entry in "${MUTANTS[@]}"; do
  IFS='|' read -r file from to claim <<< "$(printf '%s' "$entry" | sed 's/\\|/\x02/g' | tr '\n' '\001')"
  file=${file//$'\001'/$'\n'}; from=${from//$'\001'/$'\n'}; to=${to//$'\001'/$'\n'}; claim=${claim//$'\001'/$'\n'}
  from=${from//$'\002'/|}; to=${to//$'\002'/|}
  cp "$file" "$BACKUP/orig"; CURRENT="$file"
  count=$(FROM="$from" perl -0777 -ne '$f=$ENV{FROM}; $c = () = /\Q$f\E/g; print $c' "$file")
  if [ "$count" != "1" ]; then echo "SETUP ERROR: pattern occurs $count times in $file: $claim"; CURRENT=""; exit 2; fi
  FROM="$from" TO="$to" perl -0777 -pi -e 'BEGIN { $f = $ENV{FROM}; $t = $ENV{TO} } s/\Q$f\E/$t/' "$file"
  if ! swift build --build-tests -q >/dev/null 2>&1; then
    # A mutant that doesn't compile proves nothing about the tests.
    echo "SETUP ERROR: mutant does not compile: $claim"; cp "$BACKUP/orig" "$file"; CURRENT=""; exit 2
  fi
  if $LIMIT swift test --skip-build >/dev/null 2>&1; then
    echo "SURVIVED: $claim"; survived=$((survived+1))
  else
    echo "caught:   $claim"; caught=$((caught+1))
  fi
  cp "$BACKUP/orig" "$file"; CURRENT=""
done
echo "mutants caught: $caught/$((caught+survived))"
[ "$survived" -eq 0 ]
