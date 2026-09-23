import GlucoseCore
import XCTest
@testable import WidgetCore

final class ChartSeriesTests: XCTestCase {
    // MARK: S1 — the line never bridges missing data

    func test_S1_chartSegmentationNeverBridgesGapsOver15Min() {
        // 12:00, 12:05, 12:10 | 45-min gap | 12:55, 13:00 | 15:01 gap | 13:15:01
        let base = Fixture.now
        func at(_ seconds: TimeInterval, _ mgdl: Int) -> ChartPoint {
            ChartPoint(date: base.addingTimeInterval(seconds), value: .mgdl(mgdl))
        }
        let points = [
            at(0, 100), at(300, 102), at(600, 104),
            at(3_300, 150), at(3_600, 152),
            at(3_600 + 901, 160),
        ]
        let series = ChartSeries(points: points)
        XCTAssertEqual(series.segments.map { $0.map(\.mgdl) }, [[100, 102, 104], [150, 152], [160]])
        XCTAssertEqual(series.gapCount, 2)

        // Property: within every segment, consecutive points are at most 15 min apart, and every
        // plotted point is one of the input readings with its exact value.
        for segment in series.segments {
            for (a, b) in zip(segment, segment.dropFirst()) {
                XCTAssertLessThanOrEqual(b.date.timeIntervalSince(a.date), ChartSeries.maxGap)
            }
        }
        let input = Set(points.map { PlottedPoint(date: $0.date, mgdl: $0.value.numericMgdl!) })
        XCTAssertEqual(Set(series.segments.joined()), input, "no point added, removed or changed")
    }

    func test_S1_exactly15MinutesJoinsAndOneSecondMoreBreaks() {
        let a = ChartPoint(date: Fixture.now, value: .mgdl(100))
        let joined = ChartSeries(points: [a, ChartPoint(date: Fixture.now.addingTimeInterval(900), value: .mgdl(110))])
        XCTAssertEqual(joined.segments.count, 1)
        let broken = ChartSeries(points: [a, ChartPoint(date: Fixture.now.addingTimeInterval(901), value: .mgdl(110))])
        XCTAssertEqual(broken.segments.count, 2)
    }

    func test_S1_segmentationSortsAndDeduplicatesWithoutInventingPoints() {
        let points = [
            Fixture.point(.mgdl(110), minutesAgo: 0),
            Fixture.point(.mgdl(100), minutesAgo: 10),
            Fixture.point(.mgdl(105), minutesAgo: 5),
            Fixture.point(.mgdl(999), minutesAgo: 5), // same date: first in input order wins
        ]
        let series = ChartSeries(points: points)
        XCTAssertEqual(series.segments.map { $0.map(\.mgdl) }, [[100, 105, 110]])
    }

    // MARK: S4 — flags are markers at the edge, never numbers

    func test_S4_flagsBecomeEdgeMarkersNeverPlottedValues() {
        let points = [
            Fixture.point(.mgdl(60), minutesAgo: 20),
            Fixture.point(.mgdl(45), minutesAgo: 15),
            Fixture.point(.belowRange, minutesAgo: 10),
            Fixture.point(.belowRange, minutesAgo: 5),
            Fixture.point(.mgdl(42), minutesAgo: 0),
            Fixture.point(.aboveRange, minutesAgo: 30),
        ]
        let series = ChartSeries(points: points)
        let plotted = series.segments.joined().map(\.mgdl)
        XCTAssertFalse(plotted.contains(40), "LOW must not be plotted as 40")
        XCTAssertFalse(plotted.contains(400), "HIGH must not be plotted as 400")
        XCTAssertEqual(plotted.count, 3, "only the three numeric readings are plotted")
        XCTAssertEqual(series.lowFlags, [Fixture.minutesAgo(10), Fixture.minutesAgo(5)])
        XCTAssertEqual(series.highFlags, [Fixture.minutesAgo(30)])
        // A flag breaks the line: 45 → (LOW, LOW) → 42 is not joined, because the value in between
        // is unknown.
        XCTAssertEqual(series.segments.map { $0.map(\.mgdl) }, [[60, 45], [42]])
        XCTAssertEqual(series.maxPlottedMgdl, 60, "flags do not stretch the axis")
    }

    func test_S4_axisDoesNotStretchForHighFlags() {
        let series = ChartSeries(points: [Fixture.point(.aboveRange, minutesAgo: 0), Fixture.point(.mgdl(200), minutesAgo: 5)])
        XCTAssertEqual(ChartScale.yUpperBound(maxPlotted: series.maxPlottedMgdl), 250)
    }

    func test_emptyInput() {
        let series = ChartSeries(points: [])
        XCTAssertTrue(series.isEmpty)
        XCTAssertEqual(series.gapCount, 0)
        XCTAssertNil(series.maxPlottedMgdl)
    }

    // MARK: VoiceOver summary

    func test_chartSummary() {
        XCTAssertEqual(ChartSummary.text(title: "Last 3 hours", points: []), "Last 3 hours: no readings.")
        let points = [
            Fixture.point(.mgdl(82), minutesAgo: 60),
            Fixture.point(.mgdl(120), minutesAgo: 30),
            Fixture.point(.belowRange, minutesAgo: 10),
            Fixture.point(.mgdl(105), minutesAgo: 0),
        ]
        XCTAssertEqual(
            ChartSummary.text(title: "Last 3 hours", points: points),
            "Last 3 hours: 4 readings, 82 to 120 milligrams per deciliter, latest 105. 1 LOW reading. The line breaks at 2 gaps longer than 15 minutes."
        )
        XCTAssertEqual(
            ChartSummary.text(title: "Last 3 hours", points: [Fixture.point(.aboveRange, minutesAgo: 0)]),
            "Last 3 hours: 1 reading, latest HIGH. 1 HIGH reading."
        )
    }
}
