import GlucoseCore
import WidgetCore
import XCTest
@testable import Sensor

final class NowFormattingTests: XCTestCase {
    private func hero(_ latest: LatestReading?, _ state: SensorState = activeSensor, now: Date = t0) -> NowHero {
        NowHero.make(GlucoseDisplayState.classify(latest: latest, sensorState: state, now: now), now: now, context: testContext)
    }

    // MARK: S5 — the hero never shows an old or invalid number on its own

    func test_S5_heroReplacedByMessageWhenStaleOrInvalid() {
        let fresh = latest(.mgdl(105), ageMinutes: 3)
        XCTAssertEqual(hero(fresh), .reading(fresh))

        let invalid: [(String, NowHero)] = [
            ("stale (10 min)", hero(latest(.mgdl(105), ageMinutes: 10))),
            ("stale (19 min)", hero(latest(.mgdl(105), ageMinutes: 19))),
            ("no data (20 min)", hero(latest(.mgdl(105), ageMinutes: 20))),
            ("no reading ever", hero(nil)),
            ("warming up", hero(nil, .warmingUp(endsAt: minutes(45)))),
            ("expired", hero(fresh, .expired)),
            ("grace ended", hero(fresh, .gracePeriod(endsAt: minutes(-1)))),
            ("sensor error", hero(fresh, .error(code: 7, description: "Signal error"))),
            ("sensor failed", hero(fresh, .failed(reason: "Sensor failed"))),
            ("not paired", hero(nil, .notPaired)),
        ]
        for (name, result) in invalid {
            guard case .message(let title, let detail, _) = result else {
                XCTFail("\(name): hero shows a number: \(result)")
                continue
            }
            XCTAssertFalse(title.isEmpty, name)
            XCTAssertFalse(detail.isEmpty, name)
            XCTAssertNotEqual(title, "105", "\(name): the title must not be the last number alone")
        }

        // A quoted last value always comes with its time.
        guard case .message(let title, let detail, _) = hero(latest(.mgdl(105), ageMinutes: 12)) else { return XCTFail("not a message") }
        XCTAssertEqual(title, "No reading for 12 min")
        XCTAssertTrue(detail.hasPrefix("Last reading 105 mg/dL at \(TimeText.time(minutes(-12), testContext))"), detail)
    }

    func test_S5_heroGoesStaleOnTheClockWithoutANewState() {
        // The Now screen reclassifies with its own clock; the same state turns stale at 10 min.
        var state = NowViewState.empty
        state.sensorState = activeSensor
        state.latestLiveReading = latest(.mgdl(105), ageMinutes: 9)
        XCTAssertEqual(NowHero.make(state.display(now: t0), now: t0), .reading(state.latestLiveReading!))
        let later = minutes(1)
        guard case .message = NowHero.make(state.display(now: later), now: later) else { return XCTFail("still a number at 10 min") }
    }

    /// Review M1: a reading dated ahead of the phone's clock is never the hero number.
    func test_S5_futureDatedReadingIsNeverShownAsCurrent() {
        for ahead in [5.0, 60, 600] {
            let reading = latest(.mgdl(105), ageMinutes: -ahead)
            guard case .message(let title, let detail, _) = hero(reading) else {
                XCTFail("\(ahead) min ahead: hero shows a number")
                continue
            }
            XCTAssertEqual(title, "Phone clock doesn't match")
            XCTAssertTrue(detail.contains("Date & Time"), detail)
            let display = GlucoseDisplayState.classify(latest: reading, sensorState: activeSensor, now: t0)
            XCTAssertEqual(StateLine.make(display, sensorState: activeSensor, now: t0).text, "CLOCK MISMATCH · NO CURRENT READING")
            XCTAssertEqual(CalibrationRules.difference(fingerstick: 105, latest: reading, sensorState: activeSensor, now: t0), .noCurrentReading)
        }
    }

    /// Review M2: the Now chart is scrubbable in every window.
    @MainActor
    func test_nowChartIsScrubbable() {
        for window in ChartWindow.allCases {
            let options = NowContent.chartOptions(window)
            XCTAssertTrue(options.scrubbable, "\(window)")
            XCTAssertTrue(options.showsAxes)
            XCTAssertEqual(options.hourStride, window.hourStride)
        }
    }

    // MARK: S4

    func test_S4_lowHighHeroAndStateLineNeverShow40Or400() {
        for flag in [GlucoseValue.belowRange, .aboveRange] {
            let reading = latest(flag, ageMinutes: 1, trend: .notComputable, delta: nil)
            XCTAssertEqual(hero(reading), .reading(reading), "the flag itself is shown")
            let line = StateLine.make(.current(reading), sensorState: activeSensor, now: t0, context: testContext)
            XCTAssertFalse(line.text.contains("40"), line.text)
            guard case .message(_, let detail, _) = hero(latest(flag, ageMinutes: 12, delta: nil)) else { return XCTFail("not a message") }
            XCTAssertFalse(detail.contains(" 40 "), detail)
            XCTAssertFalse(detail.contains("400"), detail)
            XCTAssertTrue(detail.contains(flag == .belowRange ? "LOW" : "HIGH"), detail)
        }
        XCTAssertEqual(StateLine.make(.current(latest(.belowRange, ageMinutes: 1, trend: .fortyFiveDown)), sensorState: activeSensor, now: t0).text,
                       "FALLING SLOWLY · BELOW SENSOR RANGE · 1 MIN AGO")
        XCTAssertEqual(StateLine.make(.current(latest(.belowRange, ageMinutes: 1)), sensorState: activeSensor, now: t0).dot, .band(.veryLow))
    }

    // MARK: S1 — a calibration is never a reading

    @MainActor
    func test_S1_calibrationNotShownAsReading() {
        let model = AppModel.launch(arguments: [])
        let before = model.now
        let sensorValue = before.latestLiveReading?.value
        XCTAssertNotNil(sensorValue)

        // Submitting a fingerstick of 155 changes nothing the Now screen shows as glucose.
        model.submitCalibration(CalibrationRequest(mgdl: 155, takenAt: Date()))
        XCTAssertEqual(model.now, before, "no reading, chart point or hero change from a calibration")
        XCTAssertEqual(model.calibration.lastSubmission?.request.mgdl, 155)

        // A fingerstick marker is drawn separately; the chart's line and the hero use readings only.
        var state = before
        let marker = FingerstickMarker(date: Date().addingTimeInterval(-30), mgdl: 155)
        state.fingersticks = [marker]
        let series = ChartSeries(points: state.chartPoints)
        XCTAssertFalse(series.segments.joined().contains { $0.date == marker.date }, "the marker is not a plotted reading")
        XCTAssertFalse(state.chartPoints.contains { $0.date == marker.date })
        guard case .reading(let shown) = NowHero.make(state.display(now: Date()), now: Date()) else { return XCTFail("no reading hero") }
        XCTAssertEqual(shown.value, sensorValue, "the hero shows the sensor's reading, not the fingerstick")
        // Scrubbing the chart can only select stored readings, never the fingerstick.
        let scrub = ChartScrub.select(at: marker.date, in: state.chartPoints)
        XCTAssertNotEqual(scrub.reading?.value, .mgdl(155))
        XCTAssertNotEqual(scrub.reading?.date, marker.date)
        // Calibration status text never presents the fingerstick as a glucose reading.
        for outcome in [CalibrationSubmission.Outcome.status(.queued), .status(.accepted), .status(.rejected(code: 3, reason: "x"))] {
            XCTAssertFalse(CalibrationRules.outcomeText(outcome).title.contains("155"))
        }
    }

    // MARK: Text

    func test_stateLineMatchesTheMockup() {
        let line = StateLine.make(.current(latest(.mgdl(105), ageMinutes: 3)), sensorState: activeSensor, now: t0, context: testContext)
        XCTAssertEqual(line.text, "STEADY · IN RANGE · 3 MIN AGO")
        XCTAssertEqual(line.dot, .band(.inRange))
        XCTAssertEqual(StateLine.make(.stale(latest(.mgdl(105), ageMinutes: 12)), sensorState: activeSensor, now: t0).text, "STALE · LAST READING 12 MIN AGO")
        XCTAssertEqual(StateLine.make(.noData(last: nil), sensorState: .searching, now: t0).text, "NO DATA · SEARCHING FOR SENSOR")
        XCTAssertEqual(StateLine.make(.notPaired, sensorState: .notPaired, now: t0).text, "NO SENSOR PAIRED")
    }

    func test_statusRows() {
        XCTAssertEqual(SensorStatusText.row(activeSensor, now: t0, context: testContext), "day 6 of 10 · 4d 7h left")
        XCTAssertEqual(SensorStatusText.row(.gracePeriod(endsAt: minutes(7 * 60)), now: t0), "grace period · 7h left")
        XCTAssertEqual(SensorStatusText.row(.expired, now: t0), "expired")
        XCTAssertEqual(SensorStatusText.row(.bluetoothUnavailable(.poweredOff), now: t0), "Bluetooth off")
        XCTAssertEqual(SensorStatusText.row(.warmingUp(endsAt: minutes(-1)), now: t0), "warm-up finished · waiting for reading")
        XCTAssertEqual(TrioStatusText.row(.ok(lastHandoff: t0), context: testContext), "handed off \(TimeText.time(t0, testContext))")
        XCTAssertEqual(TrioStatusText.row(.ok(lastHandoff: nil)), "no handoff yet")
        XCTAssertEqual(TrioStatusText.row(.off), "off")
        XCTAssertTrue(TrioStatusText.row(.failing(since: t0, message: "x"), context: testContext).hasPrefix("failing since"))
        XCTAssertEqual(UploadStatusText.row(.failing(failureCount: 1, lastError: "x", since: t0), context: testContext), "1 failure since \(TimeText.time(t0, testContext))")
    }

    func test_durations() {
        XCTAssertEqual(TimeText.duration(4 * 86_400 + 7 * 3_600 + 20 * 60), "4d 7h")
        XCTAssertEqual(TimeText.duration(2 * 86_400), "2d")
        XCTAssertEqual(TimeText.duration(72 * 60), "1h 12m")
        XCTAssertEqual(TimeText.duration(3_600), "1h")
        XCTAssertEqual(TimeText.duration(35 * 60 + 59), "35m")
        XCTAssertEqual(TimeText.duration(-5), "0m")
        XCTAssertEqual(TimeText.minutesPhrase(75), "1 h 15 min")
    }

    func test_chartWindows() {
        XCTAssertEqual(ChartWindow.allCases.map(\.label), ["3H", "6H", "12H", "24H"])
        XCTAssertEqual(ChartWindow.twentyFourHours.duration, 86_400)
    }
}
