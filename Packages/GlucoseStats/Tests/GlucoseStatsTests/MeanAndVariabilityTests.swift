import XCTest
import GlucoseCore
@testable import GlucoseStats

final class MeanAndVariabilityTests: XCTestCase {

    private func variability(_ values: [GlucoseValue]) -> MeanAndVariability {
        MeanAndVariability(Fixture.period(Fixture.series(values), Fixture.interval(minutes: 1_440)))
    }

    func testMeanSampleSDAndCV() {
        // [90, 100, 110, 120, 130]
        //   mean = 550 / 5 = 110
        //   deviations −20, −10, 0, 10, 20 → squares 400, 100, 0, 100, 400 → Σ = 1 000
        //   sample variance = 1 000 / (5 − 1) = 250 → SD = √250 = 15.811388300841896
        //   CV = 15.811388300841896 / 110 × 100 = 14.373989364401724 %
        let result = variability(Fixture.mg(90, 100, 110, 120, 130))

        XCTAssertEqual(result.numericReadingCount, 5)
        XCTAssertEqual(result.meanMgdl, 110)
        XCTAssertEqual(result.standardDeviationMgdl!, 15.811388300841896, accuracy: 1e-9)
        XCTAssertEqual(result.coefficientOfVariationPercent!, 14.373989364401724, accuracy: 1e-9)
        XCTAssertEqual(result.isCoefficientOfVariationWithinTarget, true)
    }

    func testStandardDeviationIsSampleNotPopulation() {
        // [100, 200]: mean 150, deviations ±50, Σ squares = 5 000.
        //   sample (n − 1):     √(5 000 / 1) = 70.71067811865476   ← used
        //   population (n):     √(5 000 / 2) = 50                   ← not used
        //   CV = 70.71067811865476 / 150 × 100 = 47.14045207910317 % (> 36 % target)
        let result = variability(Fixture.mg(100, 200))

        XCTAssertEqual(result.meanMgdl, 150)
        XCTAssertEqual(result.standardDeviationMgdl!, 70.71067811865476, accuracy: 1e-9)
        XCTAssertNotEqual(result.standardDeviationMgdl!, 50, accuracy: 1)
        XCTAssertEqual(result.coefficientOfVariationPercent!, 47.14045207910317, accuracy: 1e-9)
        XCTAssertEqual(result.isCoefficientOfVariationWithinTarget, false)
    }

    func testSingleNumericReadingHasMeanButNoSDOrCV() {
        // Sample SD needs n ≥ 2; one reading says nothing about variability.
        let result = variability(Fixture.mg(120))
        XCTAssertEqual(result.meanMgdl, 120)
        XCTAssertNil(result.standardDeviationMgdl)
        XCTAssertNil(result.coefficientOfVariationPercent)
        XCTAssertNil(result.isCoefficientOfVariationWithinTarget)
    }

    func testEmptyInputHasNoMeanSDOrCV() {
        let result = variability([])
        XCTAssertEqual(result.numericReadingCount, 0)
        XCTAssertNil(result.meanMgdl)
        XCTAssertNil(result.standardDeviationMgdl)
        XCTAssertNil(result.coefficientOfVariationPercent)
    }

    func testLowAndHighFlagsAreExcluded() {
        // [LOW, 90, 110, HIGH]: numeric values only → [90, 110], n = 2, mean 100.
        //   sample SD = √((10² + 10²) / 1) = √200 = 14.142135623730951; CV = 14.142135623730951 %.
        let result = variability([.belowRange, .mgdl(90), .mgdl(110), .aboveRange])
        XCTAssertEqual(result.numericReadingCount, 2)
        XCTAssertEqual(result.meanMgdl, 100)
        XCTAssertEqual(result.standardDeviationMgdl!, 14.142135623730951, accuracy: 1e-9)
        XCTAssertEqual(result.coefficientOfVariationPercent!, 14.142135623730951, accuracy: 1e-9)
    }

    func testNumericValuesOutsideTheSensorRangeAreUsedAsReported() {
        // [30, 450] from imported history: mean (30 + 450) / 2 = 240; they are real numbers, not flags.
        XCTAssertEqual(variability(Fixture.mg(30, 450)).meanMgdl, 240)
    }

    func testNoCoefficientOfVariationWithoutAPositiveMean() {
        // [0, 0] (a corrupt import): mean 0, SD 0, CV = 0 / 0 is undefined → nil rather than NaN.
        let result = variability(Fixture.mg(0, 0))
        XCTAssertEqual(result.meanMgdl, 0)
        XCTAssertEqual(result.standardDeviationMgdl, 0)
        XCTAssertNil(result.coefficientOfVariationPercent)
    }

    func testCoefficientOfVariationTargetIsInclusive() {
        XCTAssertEqual(MeanAndVariability.coefficientOfVariationTargetPercent, 36)
        XCTAssertTrue(MeanAndVariability.isWithinTarget(coefficientOfVariationPercent: 36))
        XCTAssertFalse(MeanAndVariability.isWithinTarget(coefficientOfVariationPercent: 36.000_001))
    }

    func testFormulaHelpers() {
        XCTAssertNil(MeanAndVariability.mean(of: []))
        XCTAssertEqual(MeanAndVariability.mean(of: [1, 2]), 1.5)
        XCTAssertNil(MeanAndVariability.sampleStandardDeviation(of: [5], mean: 5))
        // [2, 4, 4, 4, 5, 5, 7, 9]: mean 5, Σ squares 32, sample variance 32/7 → SD 2.138089935299395.
        XCTAssertEqual(
            MeanAndVariability.sampleStandardDeviation(of: [2, 4, 4, 4, 5, 5, 7, 9], mean: 5)!,
            2.138089935299395, accuracy: 1e-12
        )
    }
}
