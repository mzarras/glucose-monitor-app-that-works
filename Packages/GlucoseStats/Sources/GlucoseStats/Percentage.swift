// Every proportion in GlucoseStats is a percentage, 0…100, unrounded. The UI rounds for display.

/// `part / whole × 100`, or `nil` when `whole` is 0 (a share of nothing is unknown, not 0 %).
/// Multiplies before dividing, so whole-number results (25, 70, 96, 100) are exact.
func percentage(_ part: Int, of whole: Int) -> Double? {
    guard whole > 0 else { return nil }
    return Double(part) * 100 / Double(whole)
}
