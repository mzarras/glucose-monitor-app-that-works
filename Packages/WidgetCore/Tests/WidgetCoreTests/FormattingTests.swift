import GlucoseCore
import XCTest
@testable import WidgetCore

final class FormattingTests: XCTestCase {
    // MARK: S4 — flags are words, never 40/400

    func test_S4_lowHighFormatAsWordsNeverAsNumbers() {
        for value in [GlucoseValue.belowRange, .aboveRange] {
            let texts = [
                GlucoseText.value(value),
                GlucoseText.valueWithUnit(value),
                GlucoseText.spoken(value),
                GlucoseText.flagCaption(value) ?? "",
                BandText.upper(value),
                HeroSpeech.label(for: LatestReading(date: Fixture.now, value: value, trend: .flat, delta: nil), now: Fixture.now),
            ]
            for text in texts {
                XCTAssertFalse(text.contains("40"), "\(value): \(text)")
                XCTAssertFalse(text.contains("400"), "\(value): \(text)")
                XCTAssertFalse(text.contains("mg/dL"), "a flag has no unit: \(text)")
            }
        }
        XCTAssertEqual(GlucoseText.value(.belowRange), "LOW")
        XCTAssertEqual(GlucoseText.value(.aboveRange), "HIGH")
        XCTAssertEqual(BandText.upper(.belowRange), "BELOW SENSOR RANGE")
        XCTAssertEqual(BandText.upper(.aboveRange), "ABOVE SENSOR RANGE")
        XCTAssertEqual(GlucoseText.spoken(.belowRange), "LOW, below the sensor's range")
    }

    func test_S4_noDeltaIsComputedAcrossAFlag() {
        let low = Fixture.reading(.belowRange, minutesAgo: 0)
        let high = Fixture.reading(.aboveRange, minutesAgo: 0)
        let numeric = Fixture.reading(.mgdl(45), minutesAgo: 5)
        XCTAssertNil(GlucoseDelta.between(latest: low, previous: numeric), "LOW minus 45 would treat LOW as a number")
        XCTAssertNil(GlucoseDelta.between(latest: high, previous: numeric))
        XCTAssertNil(GlucoseDelta.between(latest: Fixture.reading(.mgdl(45), minutesAgo: 0), previous: Fixture.reading(.belowRange, minutesAgo: 5)))
        XCTAssertNil(LatestReading(reading: low, previous: numeric).delta)
    }

    // MARK: Values

    func test_numericValueText() {
        XCTAssertEqual(GlucoseText.value(.mgdl(105)), "105")
        XCTAssertEqual(GlucoseText.valueWithUnit(.mgdl(105)), "105 mg/dL")
        XCTAssertNil(GlucoseText.flagCaption(.mgdl(105)))
        XCTAssertEqual(GlucoseText.spoken(.mgdl(105)), "105 milligrams per deciliter")
    }

    func test_bandWords() {
        XCTAssertEqual(BandText.upper(.mgdl(53)), "VERY LOW")
        XCTAssertEqual(BandText.upper(.mgdl(54)), "LOW")
        XCTAssertEqual(BandText.upper(.mgdl(69)), "LOW")
        XCTAssertEqual(BandText.upper(.mgdl(70)), "IN RANGE")
        XCTAssertEqual(BandText.upper(.mgdl(180)), "IN RANGE")
        XCTAssertEqual(BandText.upper(.mgdl(181)), "HIGH")
        XCTAssertEqual(BandText.upper(.mgdl(250)), "HIGH")
        XCTAssertEqual(BandText.upper(.mgdl(251)), "VERY HIGH")
    }

    func test_trendWordsAndGlyphsCoverEveryArrow() {
        let words = TrendArrow.allCases.map(TrendText.word)
        XCTAssertEqual(Set(words).count, TrendArrow.allCases.count, "every arrow has its own word")
        XCTAssertEqual(TrendText.word(.flat), "steady")
        XCTAssertEqual(TrendText.glyph(.flat), "→")
        XCTAssertEqual(TrendText.glyph(.doubleDown), "⇊")
        XCTAssertEqual(TrendText.glyph(.notComputable), "")
    }

    // MARK: Delta

    func test_deltaText() {
        XCTAssertEqual(DeltaText.text(GlucoseDelta(mgdl: -3, minutes: 5)), "\u{2212}3 in 5 min")
        XCTAssertEqual(DeltaText.text(GlucoseDelta(mgdl: 12, minutes: 5)), "+12 in 5 min")
        XCTAssertEqual(DeltaText.text(GlucoseDelta(mgdl: 0, minutes: 5)), "±0 in 5 min")
        XCTAssertEqual(DeltaText.spoken(GlucoseDelta(mgdl: -3, minutes: 5)), "down 3 in 5 minutes")
        XCTAssertEqual(DeltaText.spoken(GlucoseDelta(mgdl: 4, minutes: 1)), "up 4 in 1 minute")
        XCTAssertEqual(DeltaText.spoken(GlucoseDelta(mgdl: 0, minutes: 5)), "no change in 5 minutes")
    }

    func test_deltaUsesTheRealIntervalAndRefusesGaps() {
        let latest = Fixture.reading(.mgdl(105), minutesAgo: 0)
        XCTAssertEqual(GlucoseDelta.between(latest: latest, previous: Fixture.reading(.mgdl(108), minutesAgo: 5)), GlucoseDelta(mgdl: -3, minutes: 5))
        XCTAssertEqual(GlucoseDelta.between(latest: latest, previous: Fixture.reading(.mgdl(100), minutesAgo: 10)), GlucoseDelta(mgdl: 5, minutes: 10))
        XCTAssertEqual(GlucoseDelta.between(latest: latest, previous: Fixture.reading(.mgdl(100), minutesAgo: 15)), GlucoseDelta(mgdl: 5, minutes: 15), "exactly 15 min is allowed")
        XCTAssertNil(GlucoseDelta.between(latest: latest, previous: Fixture.reading(.mgdl(100), minutesAgo: 15.1)), "beyond the gap limit")
        XCTAssertNil(GlucoseDelta.between(latest: latest, previous: Fixture.reading(.mgdl(100), minutesAgo: 0)), "same instant")
        XCTAssertNil(GlucoseDelta.between(latest: latest, previous: Fixture.reading(.mgdl(100), minutesAgo: -5)), "out of order")
        XCTAssertEqual(GlucoseDelta.between(latest: latest, previous: Fixture.reading(.mgdl(100), minutesAgo: 0.2))?.minutes, 1, "never 0 min")
    }

    func test_latestReadingTakesTrendFromTheReportedRate() {
        let reading = Fixture.reading(.mgdl(150), minutesAgo: 0, rate: 2.5)
        XCTAssertEqual(LatestReading(reading: reading, previous: nil).trend, .singleUp)
        XCTAssertEqual(LatestReading(reading: Fixture.reading(.mgdl(150), minutesAgo: 0, rate: nil), previous: nil).trend, .notComputable)
    }

    // MARK: Age

    func test_ageTexts() {
        XCTAssertEqual(AgeText.wholeMinutes(from: Fixture.minutesAgo(3.9), to: Fixture.now), 3, "rounds down")
        XCTAssertEqual(AgeText.wholeMinutes(from: Fixture.minutesAgo(-0.5), to: Fixture.now), 0, "never negative")
        XCTAssertEqual(AgeText.long(minutes: 0), "just now")
        XCTAssertEqual(AgeText.long(minutes: 3), "3 min ago")
        XCTAssertEqual(AgeText.long(minutes: 65), "1 h 5 min ago")
        XCTAssertEqual(AgeText.long(minutes: 120), "2 h ago")
        XCTAssertEqual(AgeText.long(minutes: 3 * 1440 + 10), "3 d ago")
        XCTAssertEqual(AgeText.upper(minutes: 3), "3 MIN AGO")
        XCTAssertEqual(AgeText.short(minutes: 0), "now")
        XCTAssertEqual(AgeText.short(minutes: 3), "3m")
        XCTAssertEqual(AgeText.short(minutes: 65), "1h 5m")
        XCTAssertEqual(AgeText.short(minutes: 60), "1h")
        XCTAssertEqual(AgeText.short(minutes: 2 * 1440), "2d")
        XCTAssertEqual(AgeText.spoken(minutes: 1), "1 minute ago")
        XCTAssertEqual(AgeText.spoken(minutes: 3), "3 minutes ago")
        XCTAssertEqual(AgeText.spoken(minutes: 61), "1 hour 1 minute ago")
        XCTAssertEqual(AgeText.spoken(minutes: 1440), "1 day ago")
    }

    // MARK: VoiceOver hero (HANDOFF §7.5)

    func test_heroVoiceOverLabelMatchesTheSpec() {
        let reading = LatestReading(date: Fixture.minutesAgo(3), value: .mgdl(105), trend: .flat, delta: nil)
        XCTAssertEqual(HeroSpeech.label(for: reading, now: Fixture.now), "105 milligrams per deciliter, steady, 3 minutes ago")
    }

    // MARK: Axis helpers

    func test_yAxisUpperBound() {
        XCTAssertEqual(ChartScale.yUpperBound(maxPlotted: nil), 250)
        XCTAssertEqual(ChartScale.yUpperBound(maxPlotted: 200), 250)
        XCTAssertEqual(ChartScale.yUpperBound(maxPlotted: 240), 250)
        XCTAssertEqual(ChartScale.yUpperBound(maxPlotted: 241), 300)
        XCTAssertEqual(ChartScale.yUpperBound(maxPlotted: 390), 400)
        XCTAssertEqual(ChartScale.yUpperBound(maxPlotted: 400), 400, "never above the sensor's top value")
        XCTAssertEqual(ChartScale.yAxisLabels(upperBound: 250), [70, 180, 250])
    }

    func test_hourLabels() {
        XCTAssertEqual(HourLabel.text(hourOfDay: 0), "12a")
        XCTAssertEqual(HourLabel.text(hourOfDay: 6), "6a")
        XCTAssertEqual(HourLabel.text(hourOfDay: 12), "12p")
        XCTAssertEqual(HourLabel.text(hourOfDay: 13), "1p")
        XCTAssertEqual(HourLabel.text(hourOfDay: 24), "12a")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(HourLabel.text(Fixture.now, calendar: calendar), "12p")
    }
}
