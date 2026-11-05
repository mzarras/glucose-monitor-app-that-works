import GlucoseCore
import XCTest
@testable import Sensor

final class TrendsFormattingTests: XCTestCase {
    func test_periodsMatchTheSpec() {
        XCTAssertEqual(TrendsPeriod.allCases.map(\.label), ["1D", "3D", "7D", "14D", "30D", "90D"])
        XCTAssertEqual(TrendsPeriod.default, .fourteenDays)
        XCTAssertEqual(TrendsPeriod.allCases.filter(\.showsDailyTraces), [.oneDay, .threeDays])
        XCTAssertEqual(TrendsText.title(.fourteenDays), "Fourteen days")
    }

    func test_gmiOnlyFor14DaysAndLonger() {
        let gmi = 3.31 + 0.02392 * 128
        for period in [TrendsPeriod.oneDay, .threeDays, .sevenDays] {
            XCTAssertEqual(TrendsText.gmi(gmi, period: period), "needs 14 days", "\(period)")
        }
        XCTAssertEqual(TrendsText.gmi(gmi, period: .fourteenDays), "6.4%")
        XCTAssertEqual(TrendsText.gmi(gmi, period: .ninetyDays), "6.4%")
        XCTAssertEqual(TrendsText.gmi(nil, period: .thirtyDays), "—")
    }

    func test_dataSufficiencyWarningUnder70PercentOnEveryPeriod() {
        XCTAssertNotNil(TrendsText.sufficiencyWarning(69.9))
        XCTAssertNil(TrendsText.sufficiencyWarning(70))
        XCTAssertEqual(TrendsText.sufficiencyWarning(62), "Only 62% of expected readings in this period. Patterns and statistics may not be reliable.")
        // The rule does not depend on the period, so it applies to 1 D as much as to 90 D.
        for period in TrendsPeriod.allCases {
            var state = TrendsViewState.empty(period: period)
            state.dataSufficiency = 50
            XCTAssertNotNil(TrendsText.sufficiencyWarning(state.dataSufficiency))
        }
    }

    func test_rangeBinsAddUpTo100() {
        // Rounded one by one these read 2 + 3 + 91 + 6 + 0 = 102 %.
        let bins = RangeBins(veryLow: 1.5, low: 2.5, inRange: 90.5, high: 5.5, veryHigh: 0)
        XCTAssertEqual(GlucoseBand.allCases.map { bins.displayPercent(for: $0) }, [2, 3, 90, 5, 0],
                       "ties go to the lower band")
        // Rounded one by one these read 0 + 2 + 90 + 6 + 0 = 98 %. The five .4 remainders tie (up to
        // floating-point noise), so the two lowest bands get the missing points.
        let screenshot = RangeBins(veryLow: 0.4, low: 2.4, inRange: 90.4, high: 6.4, veryHigh: 0.4)
        XCTAssertEqual(GlucoseBand.allCases.map { screenshot.displayPercent(for: $0) }, [1, 3, 90, 6, 0])
        XCTAssertEqual(GlucoseBand.allCases.map { TrendsText.binPercent($0, in: screenshot) }, ["1%", "3%", "90%", "6%", "<1%"])

        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let raw = (0..<5).map { _ in Bool.random(using: &generator) ? 0 : pow(Double.random(in: 0...1, using: &generator), 3) }
            let total = raw.reduce(0, +)
            guard total > 0 else { continue }
            let percents = raw.map { $0 * 100 / total }
            let bins = RangeBins(veryLow: percents[0], low: percents[1], inRange: percents[2], high: percents[3], veryHigh: percents[4])
            let shown = GlucoseBand.allCases.map { bins.displayPercent(for: $0) }
            let hidden = zip(percents, shown).contains { $0 > 0 && $1 == 0 }
            XCTAssertTrue(shown.reduce(0, +) == 100 || (shown.reduce(0, +) == 99 && hidden), "\(percents) -> \(shown)")
            for (value, display) in zip(percents, shown) {
                XCTAssertLessThan(abs(Double(display) - value), 1, "\(percents) -> \(shown)")
                if value == 0 { XCTAssertEqual(display, 0) }
            }
        }
    }

    func test_rangeBinsNeverRead100WithAnotherBinNonZero() {
        let bins = RangeBins(veryLow: 0.3, low: 0, inRange: 99.7, high: 0, veryHigh: 0)
        XCTAssertEqual(TrendsText.binPercent(.inRange, in: bins), "99%")
        XCTAssertEqual(TrendsText.binPercent(.veryLow, in: bins), "<1%")
        let all = RangeBins(veryLow: 0, low: 0, inRange: 100, high: 0, veryHigh: 0)
        XCTAssertEqual(TrendsText.binPercent(.inRange, in: all), "100%")
        XCTAssertEqual(TrendsText.binPercent(.low, in: all), "0%")
        XCTAssertEqual(RangeBins(veryLow: 0, low: 0, inRange: 0, high: 0, veryHigh: 0).displayPercent(for: .inRange), 0)
    }

    func test_heroMatchesTheInRangeBin() {
        var state = TrendsViewState.empty(period: .sevenDays)
        XCTAssertNil(TrendsText.heroPercent(state))
        state.timeInRange = 90.5
        XCTAssertEqual(TrendsText.heroPercent(state), 91, "no bins: plain rounding")
        state.rangeBins = RangeBins(veryLow: 1.5, low: 2.5, inRange: 90.5, high: 5.5, veryHigh: 0)
        XCTAssertEqual(TrendsText.heroPercent(state), 90, "with bins: the same number as the 70–180 bin")
        XCTAssertTrue(TrendsText.heroSpeech(state).hasPrefix("90 percent time in range"))
    }

    func test_comparisonWithPriorPeriod() {
        XCTAssertEqual(TrendsText.change(4, period: .fourteenDays), "+4 pts vs prior 14d")
        XCTAssertEqual(TrendsText.change(-3, period: .oneDay), "\u{2212}3 pts vs yesterday")
        XCTAssertEqual(TrendsText.change(0.4, period: .threeDays), "±0 pts vs prior 3 days")
        XCTAssertEqual(TrendsText.change(nil, period: .sevenDays), "no prior data to compare")
        var state = TrendsViewState.empty(period: .fourteenDays)
        state.timeInRange = 78
        state.timeInRangeChange = 4
        XCTAssertEqual(TrendsText.heroSpeech(state), "78 percent time in range, 70 to 180 milligrams per deciliter, up 4 points compared with the prior 14 days")
    }

    func test_numbersAndLabels() {
        XCTAssertEqual(TrendsText.percent(61.4), "61%")
        XCTAssertEqual(TrendsText.percent(nil), "—")
        let bins = RangeBins(veryLow: 0.3, low: 2.1, inRange: 77.6, high: 20, veryHigh: 0)
        XCTAssertEqual(TrendsText.binPercent(.veryHigh, in: bins), "0%")
        XCTAssertEqual(TrendsText.binPercent(.veryLow, in: bins), "<1%", "a real low never reads as none")
        XCTAssertEqual(TrendsText.binPercent(.inRange, in: bins), "78%")
        XCTAssertEqual(TrendsText.mgdl(127.6), "128")
        XCTAssertEqual(TrendsText.streak(11 * 3_600 + 20 * 60), "11h 20m")
        XCTAssertEqual(TrendsText.hourRange(2, 5), "2–5 AM")
        XCTAssertEqual(TrendsText.hourRange(22, 1), "10 PM–1 AM")
        XCTAssertEqual(TrendsText.hourRange(11, 14), "11 AM–2 PM")
        let lows = LowsSummary(count: 6, meanDurationMinutes: 32, peakWindow: HourWindow(startHour: 2, endHour: 5, count: 4))
        XCTAssertEqual(TrendsText.lowsNote(lows), "4 of 6 between 2–5 AM")
        XCTAssertEqual(TrendsText.lowsDuration(lows), "avg 32m")
        XCTAssertNil(TrendsText.lowsNote(LowsSummary(count: 0, meanDurationMinutes: nil, peakWindow: nil)))
    }

    func test_dateRangeAndImportedFootnote() {
        let start = Date(timeIntervalSince1970: 1_788_998_400) // 2026-09-10 00:00 UTC
        XCTAssertEqual(TrendsText.dateRange(DateInterval(start: start, end: t0), context: testContext), "SEP 10 – SEP 23")
        XCTAssertEqual(TrendsText.dateRange(nil), "NO DATA")
        let note = ImportedDataNote(origins: [.nightscout, .clarityCSV], interval: DateInterval(start: start, duration: 5 * 86_400))
        XCTAssertEqual(
            TrendsText.importedFootnote(note, context: testContext),
            "Includes history imported from Nightscout and a Clarity export (Sep 10 – Sep 14). Imported readings are used for charts and statistics only."
        )
        XCTAssertNil(TrendsText.importedFootnote(nil))
    }

    func test_afterExerciseRowHiddenUntilV1_1() {
        XCTAssertFalse(FeatureFlags.showsAfterExerciseRow)
    }

    func test_agpSegmentsNeverBridgeMissingBuckets() {
        let buckets = [0, 15, 30, 150, 165].map { AGPBucket(minuteOfDay: $0, p5: 80, p25: 100, p50: 120, p75: 140, p95: 180) }
        XCTAssertEqual(AGPSegmentation.segments(buckets).map { $0.map(\.minuteOfDay) }, [[0, 15, 30], [150, 165]])
    }
}
