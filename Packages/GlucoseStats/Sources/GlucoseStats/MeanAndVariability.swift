// Mean glucose, standard deviation and coefficient of variation (HANDOFF §6; Battelino et al.,
// Diabetes Care 2019;42:1593, Table 2: "Glycemic Variability (%CV) Target <36%"; HANDOFF §6 says
// "≤ 36%", which is what is implemented — the two differ only at exactly 36.0 %).

/// Mean, SD and CV over the numeric readings of a period.
///
/// - LOW and HIGH flags are excluded (S4, HANDOFF §6): they are not numbers, and substituting 40 or
///   400 would invent values. `numericReadingCount` says how many readings were used.
/// - **SD is the sample SD (n − 1).** A period's readings are a sample of a continuous glucose
///   curve, and the n − 1 form matches the reference tools a reviewer would cross-check against
///   (R `sd()`, used by the iglu and cgmanalysis packages; Excel `STDEV.S`). It is undefined for a
///   single reading, so one reading never produces a misleading "CV 0 %". Over a 14-day period
///   (~4 000 readings) the two forms differ by about 0.01 %.
public struct MeanAndVariability: Sendable, Equatable {
    /// Target for glycaemic variability: CV ≤ 36 % (HANDOFF §6; Battelino et al. 2019, Table 2).
    public static let coefficientOfVariationTargetPercent: Double = 36

    /// Readings with a numeric value (LOW/HIGH excluded).
    public let numericReadingCount: Int
    /// mg/dL; `nil` without numeric readings.
    public let meanMgdl: Double?
    /// Sample SD in mg/dL; `nil` with fewer than 2 numeric readings.
    public let standardDeviationMgdl: Double?
    /// CV = SD / mean × 100, in percent; `nil` when SD is `nil` or the mean is not positive.
    public let coefficientOfVariationPercent: Double?

    /// CV ≤ 36 %; `nil` when there is no CV.
    public var isCoefficientOfVariationWithinTarget: Bool? {
        coefficientOfVariationPercent.map { Self.isWithinTarget(coefficientOfVariationPercent: $0) }
    }

    public init(_ period: PeriodReadings) {
        var values: [Int] = []
        values.reserveCapacity(period.readings.count)
        period.forEachReading { _, reading in
            if let value = reading.value.numericMgdl { values.append(value) }
        }
        let mean = Self.mean(of: values)
        let standardDeviation = mean.flatMap { Self.sampleStandardDeviation(of: values, mean: $0) }

        numericReadingCount = values.count
        meanMgdl = mean
        standardDeviationMgdl = standardDeviation
        if let standardDeviation, let mean, mean > 0 {
            coefficientOfVariationPercent = standardDeviation / mean * 100
        } else {
            coefficientOfVariationPercent = nil
        }
    }

    /// Arithmetic mean; `nil` for no values. Sums in `Double` so no input can overflow.
    public static func mean(of values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        var sum = 0.0
        for value in values { sum += Double(value) }
        return sum / Double(values.count)
    }

    /// √( Σ (x − mean)² / (n − 1) ); `nil` for fewer than 2 values. Two-pass (mean given).
    public static func sampleStandardDeviation(of values: [Int], mean: Double) -> Double? {
        guard values.count >= 2 else { return nil }
        var sumOfSquares = 0.0
        for value in values {
            let deviation = Double(value) - mean
            sumOfSquares += deviation * deviation
        }
        return (sumOfSquares / Double(values.count - 1)).squareRoot()
    }

    public static func isWithinTarget(coefficientOfVariationPercent: Double) -> Bool {
        coefficientOfVariationPercent <= coefficientOfVariationTargetPercent
    }
}
