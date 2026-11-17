/// Saturating integer arithmetic.
///
/// Every count, byte total and token estimate in this package goes through these
/// helpers instead of `+`/`*`, which trap on overflow. Budgets come from callers
/// (and, in the demo, from a UI), so "nobody will pass a value that big" is not a
/// guarantee this code is willing to rely on. The ceiling is `Int.max` of the
/// platform, never a hard-coded 64-bit literal.
enum Saturating {
    static func add(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return result }
        return b > 0 ? .max : .min
    }

    static func multiply(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return result }
        return (a < 0) == (b < 0) ? .max : .min
    }

    /// Ceiling division for non-negative numerators and positive divisors.
    /// A divisor below 1 is treated as 1, so this never divides by zero.
    static func ceilDivide(_ numerator: Int, by divisor: Int) -> Int {
        let n = max(0, numerator)
        let d = max(1, divisor)
        let (q, r) = n.quotientAndRemainder(dividingBy: d)
        return r == 0 ? q : add(q, 1)
    }

    /// Sum of 0 + 1 + ... + n, saturating. Used by the cost model (each turn of
    /// classic tool use re-reads every earlier tool result).
    static func triangular(_ n: Int) -> Int {
        let n = max(0, n)
        // n * (n + 1) / 2, dividing the even factor first so the product overflows later.
        let next = add(n, 1)
        return n % 2 == 0 ? multiply(n / 2, next) : multiply(n, next / 2)
    }
}
