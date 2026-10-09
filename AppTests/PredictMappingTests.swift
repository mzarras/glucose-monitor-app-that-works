// PROGRESS D57: what the Predict tab shows for every forecast state, at an injected instant
// (`PredictMapping.make`). Documents go through ForecastKit's decoder, as in the app; times are whole
// seconds around t0 (12:35 UTC; `testContext` is en_US in UTC).

import ForecastKit
import GlucoseCore
import WidgetCore
import XCTest
@testable import Sensor

final class PredictMappingTests: XCTestCase {
    private let ranAt = minutes(-3) // 12:32

    /// 3 h of live readings every 5 min ending at the run's time (one exactly at 12:32).
    private func readings(endingAt end: Date? = nil, value: GlucoseValue = .mgdl(105)) -> [GlucoseReading] {
        let last = end ?? ranAt
        return stride(from: -36, through: 0, by: 1).map { sensorReading(last.addingTimeInterval(Double($0) * 300), value) }
    }

    /// Clock times come with U+202F before AM/PM (Foundation's format); compare with plain spaces.
    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func make(_ status: ForecastStatus, readings: [GlucoseReading]? = nil, at wall: Date = t0) -> PredictViewState {
        make(status, readings: readings, at: ForecastFixtureDocuments.instant(wall))
    }

    /// At an explicit instant (both clocks), e.g. after the phone's clock was set back.
    private func make(_ status: ForecastStatus, readings: [GlucoseReading]? = nil, at instant: ForecastInstant) -> PredictViewState {
        PredictMapping.make(status: status, readings: readings ?? self.readings(), at: instant, context: testContext)
    }

    private func currentStatus(failures: Int = 0) -> ForecastStatus {
        ForecastTestDocuments.status(latest: ForecastTestDocuments.decodedLatest(run: ranAt, now: t0),
                                     accuracy: ForecastTestDocuments.accuracy(now: t0), failures: failures,
                                     error: failures > 0 ? "Could not reach the forecast feed: offline." : nil)
    }

    // MARK: - Current

    func test_currentRunShowsThreeColumnsLabelledPredicted() throws {
        let state = make(currentStatus())
        let forecast = try XCTUnwrap(state.forecast)
        XCTAssertEqual(forecast.columns.map(\.title), ["+30 MIN", "+1 HR", "+2 HR"])
        XCTAssertEqual(forecast.columns.map(\.value), ["98", "105", "121"]) // 98.2, 104.6, 121.3
        XCTAssertEqual(forecast.columns.map(\.caption), ["predicted", "predicted", "predicted"])
        XCTAssertEqual(forecast.columns.map(\.typicalMiss), ["typical miss ±16", "typical miss ±23", "typical miss ±31"])
        XCTAssertEqual(forecast.columns.map(\.band), [.inRange, .inRange, .inRange])
        XCTAssertEqual(forecast.columns[0].spoken, "Predicted 98 milligrams per deciliter in 30 minutes, typical miss 16")
        XCTAssertEqual(forecast.columns[1].spoken, "Predicted 105 milligrams per deciliter in 1 hour, typical miss 23")
        XCTAssertEqual(forecast.columns[2].spoken, "Predicted 121 milligrams per deciliter in 2 hours, typical miss 31")
        XCTAssertEqual(plain(forecast.freshnessLine), "MODEL RAN 12:32 PM · 3 MIN AGO · FROM 105 AT 12:32 PM")
        XCTAssertNil(state.refreshNote)
        XCTAssertEqual(state.accuracyNote, "Typical miss over the last 7 days (mean absolute error, 2,016 model runs): ±16 at 30 min, ±23 at 1 hr, ±31 at 2 hr.")
        XCTAssertEqual(state.modelVersion, "MODEL \(ForecastFixtureDocuments.modelVersion)")
        XCTAssertEqual(state.redrawAt, ranAt.addingTimeInterval(15 * 60 + 1))
    }

    func test_typicalMissIsHiddenWithoutAccuracy() throws {
        var status = currentStatus()
        status.accuracy = nil
        let state = make(status)
        XCTAssertEqual(try XCTUnwrap(state.forecast).columns.map(\.typicalMiss), [nil, nil, nil])
        XCTAssertEqual(try XCTUnwrap(state.forecast).columns[0].spoken, "Predicted 98 milligrams per deciliter in 30 minutes")
        XCTAssertNil(state.accuracyNote)
    }

    func test_aHorizonThatIsNotPublishedShowsADash() throws {
        let latest = ForecastTestDocuments.decodedLatest(run: ranAt, zen: [5: 103.8, 30: 98.2, 120: 121.3], now: t0)
        let state = make(ForecastTestDocuments.status(latest: latest))
        let columns = try XCTUnwrap(state.forecast).columns
        XCTAssertEqual(columns.map(\.value), ["98", "—", "121"])
        XCTAssertEqual(columns[1].caption, "not published")
        XCTAssertNil(columns[1].band)
        XCTAssertEqual(columns[1].spoken, "No prediction published for 1 hour")
    }

    /// D59: ForecastKit's `modelBound` decides "≤40"/"≥400"; on top of it a value that rounds to 40
    /// or 400 never shows as a bare 40/400 that would look like a sensor value.
    func test_modelBoundDrivesTheClipEdges() throws {
        // modelBound drives, whatever the number (a contrived pair, to show which one decides).
        XCTAssertEqual(PredictMapping.clipEdge(41, bound: .atOrBelowFloor), .atOrBelowFloor)
        XCTAssertEqual(PredictMapping.clipEdge(390, bound: .atOrAboveCeiling), .atOrAboveCeiling)
        // Rounding guard inside the clip.
        XCTAssertEqual(PredictMapping.clipEdge(40.4, bound: .within), .atOrBelowFloor, "rounds to 40: never a bare 40")
        XCTAssertEqual(PredictMapping.clipEdge(40.5, bound: .within), .within)
        XCTAssertEqual(PredictMapping.clipEdge(399.4, bound: .within), .within)
        XCTAssertEqual(PredictMapping.clipEdge(399.5, bound: .within), .atOrAboveCeiling, "rounds to 400: never a bare 400")
        XCTAssertEqual(PredictMapping.valueText(41, edge: .atOrBelowFloor), "≤40")
        XCTAssertEqual(PredictMapping.valueText(390, edge: .atOrAboveCeiling), "≥400")
        XCTAssertEqual(PredictMapping.valueText(40.5, edge: .within), "41")
        XCTAssertEqual(PredictMapping.spokenValue(40, edge: .atOrBelowFloor), "40 milligrams per deciliter or below")
        XCTAssertEqual(PredictMapping.spokenValue(400, edge: .atOrAboveCeiling), "400 milligrams per deciliter or above")
        XCTAssertEqual(PredictMapping.spokenValue(98.2, edge: .within), "98 milligrams per deciliter")
        XCTAssertEqual(PredictMapping.band(41, edge: .atOrBelowFloor), .veryLow)
        XCTAssertEqual(PredictMapping.band(390, edge: .atOrAboveCeiling), .veryHigh)
        XCTAssertEqual(PredictMapping.band(62.4, edge: .within), .low)
        XCTAssertEqual(PredictMapping.band(181, edge: .within), .high)

        // From a decoded document: the published 40 and 400 carry ForecastKit's bound.
        let latest = try XCTUnwrap(ForecastTestDocuments.decodedLatest(run: ranAt, zen: [5: 40, 30: 40.4, 60: 400, 120: 230], now: t0))
        let run = try XCTUnwrap(PredictFreshness.currentRun(latest, at: ForecastFixtureDocuments.instant(t0)))
        XCTAssertEqual(run.points.map(\.modelBound), [.atOrBelowFloor, .within, .atOrAboveCeiling, .within])
        XCTAssertEqual(try XCTUnwrap(make(ForecastTestDocuments.status(latest: latest)).forecast).columns.map(\.value), ["≤40", "≥400", "230"])
    }

    func test_clippedRunShowsTheEdgesAndPlotsInsideTheAxis() throws {
        let latest = ForecastTestDocuments.decodedLatest(run: ranAt, zen: [5: 52.3, 30: 40, 60: 40, 120: 47.6], now: t0)
        let state = make(ForecastTestDocuments.status(latest: latest))
        let forecast = try XCTUnwrap(state.forecast)
        XCTAssertEqual(forecast.columns.map(\.value), ["≤40", "≤40", "48"])
        XCTAssertEqual(forecast.columns[0].spoken, "Predicted 40 milligrams per deciliter or below in 30 minutes")
        XCTAssertEqual(try XCTUnwrap(state.chart).forecast.filter(\.isPredicted).map(\.mgdl), [52.3, 40, 40, 47.6])

        let high = ForecastTestDocuments.decodedLatest(run: ranAt, zen: [5: 371.2, 30: 400, 60: 400, 120: 396.4], now: t0)
        XCTAssertEqual(try XCTUnwrap(make(ForecastTestDocuments.status(latest: high)).forecast).columns.map(\.value), ["≥400", "≥400", "396"])
    }

    // MARK: - Freshness: the 15-minute rule at the UI instant

    func test_S1_exactlyFifteenMinutesIsCurrentAndOneMomentMoreIsOutOfDate() throws {
        let status = currentStatus()
        let boundary = ranAt.addingTimeInterval(15 * 60)
        let atBoundary = make(status, at: boundary)
        XCTAssertNotNil(atBoundary.forecast, "age 15:00 is still current (ForecastFreshness: stale when age > 15 min)")
        XCTAssertEqual(plain(atBoundary.forecast?.freshnessLine), "MODEL RAN 12:32 PM · 15 MIN AGO · FROM 105 AT 12:32 PM")

        let past = make(status, at: boundary.addingTimeInterval(0.001))
        XCTAssertNil(past.forecast)
        XCTAssertTrue(try XCTUnwrap(past.chart).forecast.isEmpty, "no forecast line once out of date")
        XCTAssertNil(past.redrawAt)
        guard case .outOfDate(let message) = past.content else { return XCTFail("\(past.content)") }
        XCTAssertEqual(message.title, "Forecast out of date")
        XCTAssertTrue(plain(message.detail)?.hasPrefix("Last model run 15 min ago, at 12:32 PM.") == true, message.detail)
    }

    /// D59: the phone's clock set back 10 minutes after the document arrived. By the wall clock the
    /// run would look 10 minutes younger; ForecastKit's monotonic age still ends it on time.
    func test_S1_clockSetBackTenMinutesStillTurnsOutOfDateOnTimeByTheMonotonicClock() throws {
        let arrived = ForecastFixtureDocuments.instant(t0) // run at 12:32, arrived at 12:35
        let status = currentStatus()
        func setBack(realElapsed: TimeInterval) -> ForecastInstant {
            ForecastInstant(wall: t0.addingTimeInterval(realElapsed - 10 * 60), monotonic: arrived.monotonic + realElapsed)
        }
        // 12 min of real time after arrival: 15 min old, still current, and its age is the real one.
        let atLimit = make(status, at: setBack(realElapsed: 12 * 60))
        XCTAssertEqual(plain(atLimit.forecast?.freshnessLine), "MODEL RAN 12:32 PM · 15 MIN AGO · FROM 105 AT 12:32 PM", "not the wall clock's 5 min")

        // One second later it is out of date, although the wall clock says the run is 5 min old.
        let past = make(status, at: setBack(realElapsed: 12 * 60 + 1))
        XCTAssertNil(past.forecast)
        XCTAssertTrue(try XCTUnwrap(past.chart).forecast.isEmpty, "no forecast line")
        guard case .outOfDate(let message) = past.content else { return XCTFail("\(past.content)") }
        XCTAssertTrue(plain(message.detail)?.hasPrefix("Last model run 15 min ago, at 12:32 PM.") == true, message.detail)
    }

    func test_S1_staleRunShowsNoNumbersButKeepsTheReadings() throws {
        let latest = ForecastTestDocuments.decodedLatest(run: minutes(-32), now: t0)
        let state = make(ForecastTestDocuments.status(latest: latest, accuracy: ForecastTestDocuments.accuracy(now: t0)),
                         readings: readings(endingAt: minutes(-2)))
        XCTAssertNil(state.forecast)
        guard case .outOfDate(let message) = state.content else { return XCTFail("\(state.content)") }
        XCTAssertEqual(plain(message.detail), "Last model run 32 min ago, at 12:03 PM. Zen Predict runs on readings that reach Nightscout; a new forecast appears after the next one does.")
        let chart = try XCTUnwrap(state.chart)
        XCTAssertTrue(chart.forecast.isEmpty)
        XCTAssertFalse(chart.readings.isEmpty, "the readings chart is still shown")
        XCTAssertEqual(chart.domain, minutes(-180)...t0, "no room for a forecast")
        XCTAssertNil(chart.forecastLegend)
        XCTAssertTrue(chart.accessibilityLabel.hasSuffix("No forecast shown."), chart.accessibilityLabel)
    }

    func test_S1_runAheadOfThePhonesClockIsTreatedAsOutOfDate() throws {
        // Decoded while the clock was 10 min later, then the clock was set back.
        let latest = ForecastTestDocuments.decodedLatest(run: minutes(5), now: minutes(10))
        let state = make(ForecastTestDocuments.status(latest: latest))
        XCTAssertNil(state.forecast)
        XCTAssertTrue(try XCTUnwrap(state.chart).forecast.isEmpty)
        guard case .outOfDate(let message) = state.content else { return XCTFail("\(state.content)") }
        XCTAssertEqual(message.detail, "The last model run is dated 5 min ahead of this phone's clock, so it can't be shown. Check the phone's date and time.")

        // Up to 2 minutes ahead is clock skew: current, age "just now".
        let slightlyAhead = ForecastTestDocuments.decodedLatest(run: minutes(1), now: t0)
        XCTAssertEqual(plain(make(ForecastTestDocuments.status(latest: slightlyAhead)).forecast?.freshnessLine),
                       "MODEL RAN 12:36 PM · JUST NOW")
    }

    func test_failingFetchKeepsACurrentRunWithARetryNoteUntilItAgesOut() throws {
        let status = currentStatus(failures: 2)
        let state = make(status)
        XCTAssertNotNil(state.forecast, "a current run held while fetches fail is still shown")
        XCTAssertEqual(state.refreshNote, "COULDN'T REFRESH · RETRYING")

        let later = make(status, at: minutes(13))
        XCTAssertNil(later.forecast, "it turns out of date on time, with no new fetch")
        XCTAssertEqual(later.refreshNote, "COULDN'T REFRESH · RETRYING")
        guard case .outOfDate = later.content else { return XCTFail("\(later.content)") }
    }

    // MARK: - States without a run

    func test_statesWithoutAForecastShowNoNumbers() throws {
        let host = ForecastTestDocuments.host
        XCTAssertEqual(make(.notConfigured), .notConfigured)
        XCTAssertNil(PredictViewState.notConfigured.chart)

        let off = make(ForecastStatus(setup: .off(host: host), buildHost: host))
        XCTAssertEqual(off.content, .turnedOff(host: host))
        XCTAssertNil(off.chart)

        var waiting = ForecastTestDocuments.status(latest: nil)
        waiting.isFetching = true
        let waitingState = make(waiting)
        XCTAssertEqual(waitingState.content, .waiting(host: host))
        XCTAssertTrue(try XCTUnwrap(waitingState.chart).forecast.isEmpty)
        XCTAssertFalse(try XCTUnwrap(waitingState.chart).readings.isEmpty)

        let noRun = make(ForecastTestDocuments.status(latest: ForecastTestDocuments.decodedLatest(run: nil, zen: nil, now: t0)))
        guard case .noRunYet(let message) = noRun.content else { return XCTFail("\(noRun.content)") }
        XCTAssertEqual(message.title, "No forecast yet")
        XCTAssertNil(noRun.refreshNote)

        let unavailable = make(ForecastTestDocuments.status(latest: nil, failures: 3, error: "The forecast feed answered HTTP 403."))
        XCTAssertEqual(unavailable.content, .unavailable(PredictMessage(title: "Forecast unavailable", detail: "The forecast feed answered HTTP 403. Retrying.")))
        XCTAssertNil(unavailable.refreshNote, "nothing held: the message says it")
        XCTAssertTrue(try XCTUnwrap(unavailable.chart).forecast.isEmpty)

        for state in [waitingState, noRun, unavailable] {
            XCTAssertNil(state.forecast)
            XCTAssertNil(state.redrawAt)
        }
    }

    // MARK: - The reading the run is labelled with

    func test_baseReadingIsTheClosestLiveReadingWithinHalfACadence() {
        let live150 = sensorReading(ranAt.addingTimeInterval(-150), .mgdl(101))
        let live151 = sensorReading(ranAt.addingTimeInterval(151), .mgdl(102))
        let importedExact = importedReading(ranAt, .mgdl(150))
        XCTAssertEqual(PredictMapping.baseReading(at: ranAt, in: [live150, live151, importedExact]), live150, "±150 s; imported history never counts")
        XCTAssertNil(PredictMapping.baseReading(at: ranAt, in: [live151, importedExact]))
        let closer = sensorReading(ranAt.addingTimeInterval(40), .mgdl(103))
        XCTAssertEqual(PredictMapping.baseReading(at: ranAt, in: [live150, closer]), closer)
        let low = sensorReading(ranAt, .belowRange)
        XCTAssertEqual(PredictMapping.baseReading(at: ranAt, in: [low]), low)
    }

    func test_S1_feedGlucoseIsNeverShownAsAReading() throws {
        // The feed's own `bg` says 105 at the run's time, but this phone stored no reading then.
        let latest = ForecastTestDocuments.decodedLatest(run: ranAt, feedGlucose: 105, now: t0)
        let state = make(ForecastTestDocuments.status(latest: latest), readings: readings(endingAt: minutes(-10)))
        let forecast = try XCTUnwrap(state.forecast)
        XCTAssertEqual(plain(forecast.freshnessLine), "MODEL RAN 12:32 PM · 3 MIN AGO")
        let chart = try XCTUnwrap(state.chart)
        XCTAssertEqual(chart.forecast.first?.isPredicted, true, "without a stored reading the line starts at the first predicted point")
        XCTAssertFalse(chart.readings.contains { $0.date == ranAt }, "the feed's bg never joins the readings")
    }

    func test_S4_aLowFlagAtTheRunsTimeIsNamedButNotPlotted() throws {
        var stored = readings(endingAt: minutes(-8))
        stored.append(sensorReading(ranAt, .belowRange))
        let state = make(currentStatus(), readings: stored)
        XCTAssertEqual(plain(try XCTUnwrap(state.forecast).freshnessLine), "MODEL RAN 12:32 PM · 3 MIN AGO · FROM LOW AT 12:32 PM")
        let chart = try XCTUnwrap(state.chart)
        XCTAssertTrue(chart.forecast.allSatisfy(\.isPredicted), "a LOW has no number to start the line from")
        XCTAssertEqual(chart.readings.last?.value, .belowRange, "the flag stays a flag in the readings")
    }

    // MARK: - Chart

    func test_chartShowsThreeHoursOfReadingsAndTheForecastToTwoHoursAfterTheRun() throws {
        var stored = readings()
        stored.append(sensorReading(minutes(1), .mgdl(110))) // dated after now (clock set back): not drawn
        stored.append(sensorReading(minutes(-181), .mgdl(90))) // older than 3 h
        stored.append(importedReading(minutes(-60).addingTimeInterval(60), .mgdl(130))) // history may be charted
        let state = make(currentStatus(), readings: stored)
        let chart = try XCTUnwrap(state.chart)
        XCTAssertEqual(chart.domain, minutes(-180)...ranAt.addingTimeInterval(2 * 3_600 + 5 * 60), "to the run's +2 h, plus room for its marker")
        XCTAssertEqual(chart.now, t0)
        XCTAssertTrue(chart.readings.allSatisfy { $0.date >= minutes(-180) && $0.date <= t0 })
        XCTAssertTrue(chart.readings.contains { $0.value == .mgdl(130) })
        XCTAssertEqual(chart.forecast.map(\.date), [ranAt, ranAt.addingTimeInterval(300), ranAt.addingTimeInterval(1_800),
                                                    ranAt.addingTimeInterval(3_600), ranAt.addingTimeInterval(7_200)])
        XCTAssertEqual(chart.forecast.map(\.isPredicted), [false, true, true, true, true], "starts at the stored reading")
        XCTAssertEqual(chart.forecast.map(\.mgdl), [105, 103.8, 98.2, 104.6, 121.3])
        XCTAssertEqual(plain(chart.forecastLegend), "predicted · model run 12:32 PM")
        XCTAssertTrue(plain(chart.accessibilityLabel)!.contains("Dashed line: predicted by your Zen Predict model from the 12:32 PM run: 98 in 30 minutes, 105 in 1 hour, 121 in 2 hours. The predicted part is not readings."),
                      chart.accessibilityLabel)
        XCTAssertTrue(chart.accessibilityLabel.hasPrefix("Last 3 hours: "), chart.accessibilityLabel)
    }

    func test_chartReadingsKeptByTheModelAreTheLastThreeHours() {
        let stored = [sensorReading(minutes(-200), .mgdl(90)), sensorReading(minutes(-170), .mgdl(91)), sensorReading(minutes(0.5), .mgdl(92))]
        XCTAssertEqual(PredictMapping.chartReadings(stored.reversed(), now: t0).map(\.date), [minutes(-170), minutes(0.5)])
    }

    // MARK: - oref (S3: it has no time, so it is not shown in v1)

    func test_S3_predictNeverShowsOref() throws {
        let oref: [Int: Double] = [5: 333, 30: 277, 60: 222, 120: 188]
        // The document carries these oref values (`ForecastFixtureDocuments.latest`); the app has no
        // way to read them back (D59: `LatestForecast.oref` is internal), so check the view state.
        let latest = ForecastTestDocuments.decodedLatest(run: ranAt, oref: oref, now: t0)
        XCTAssertNotNil(latest)
        let state = make(ForecastTestDocuments.status(latest: latest, accuracy: ForecastTestDocuments.accuracy(now: t0)))
        let chart = try XCTUnwrap(state.chart)
        XCTAssertEqual(Set(chart.forecast.filter(\.isPredicted).map(\.mgdl)), Set(ForecastFixtureDocuments.zen.values), "only Zen points are drawn")
        let text = [String(describing: state.content), chart.accessibilityLabel, chart.forecastLegend ?? "", state.accuracyNote ?? ""].joined(separator: " ")
        for value in ["333", "277", "222", "188"] {
            XCTAssertFalse(text.contains(value), "oref \(value) shown: \(text)")
        }
        XCTAssertFalse(text.lowercased().contains("oref"))
    }

    // MARK: - Settings › Predictions

    func test_settingsRowAndLastUpdated() {
        XCTAssertEqual(PredictMapping.settings(.notConfigured).rowValue, "not set up")
        XCTAssertEqual(PredictMapping.settings(ForecastStatus(setup: .off(host: "zen.example.com"))).rowValue, "off")
        var status = ForecastStatus(setup: .on(host: "zen.example.com"), buildHost: "zen.example.com")
        status.lastSuccessAt = minutes(-2)
        XCTAssertEqual(PredictMapping.settings(status).rowValue, "on · zen.example.com")
        XCTAssertNil(PredictMapping.settings(status).lastError)
        status.consecutiveFailures = 1
        status.lastError = "The forecast feed answered HTTP 403."
        XCTAssertEqual(PredictMapping.settings(status).lastError, "The forecast feed answered HTTP 403.")
        XCTAssertEqual(PredictMapping.lastUpdatedText(minutes(-2), now: t0), "Last updated 2 min ago")
        XCTAssertEqual(PredictMapping.lastUpdatedText(minutes(-0.5), now: t0), "Last updated just now")
        XCTAssertEqual(PredictMapping.lastUpdatedText(nil, now: t0), "Not updated yet")
    }

    func test_setupRulesResolveTheHostAndTheSwitch() {
        XCTAssertEqual(ForecastSetupRules.resolve(buildHost: "", savedHost: nil, savedEnabled: nil).setup, .notConfigured)
        XCTAssertEqual(ForecastSetupRules.resolve(buildHost: nil, savedHost: nil, savedEnabled: true).setup, .notConfigured)
        XCTAssertEqual(ForecastSetupRules.resolve(buildHost: "zen.example.com", savedHost: nil, savedEnabled: nil).setup, .on(host: "zen.example.com"),
                       "on by default once a host is configured")
        XCTAssertEqual(ForecastSetupRules.resolve(buildHost: "zen.example.com", savedHost: nil, savedEnabled: false).setup, .off(host: "zen.example.com"))
        XCTAssertEqual(ForecastSetupRules.resolve(buildHost: "zen.example.com", savedHost: "Other.Example.org", savedEnabled: nil).setup,
                       .on(host: "other.example.org"), "the saved host wins")
        XCTAssertEqual(ForecastSetupRules.resolve(buildHost: "", savedHost: "other.example.org", savedEnabled: nil).setup, .on(host: "other.example.org"))
        let invalidBuild = ForecastSetupRules.resolve(buildHost: "http://zen.example.com", savedHost: nil, savedEnabled: nil)
        XCTAssertEqual(invalidBuild.setup, .notConfigured)
        XCTAssertNil(invalidBuild.buildHost)
        XCTAssertEqual(ForecastSetupRules.resolve(buildHost: "zen.example.com", savedHost: "not a host", savedEnabled: nil).setup, .on(host: "zen.example.com"))
    }

    // MARK: - Fixtures (previews and screenshots use the real mapping)

    func test_fixtureScenariosMapToTheirStates() {
        #if DEBUG
        func content(_ scenario: PredictFixtures.Scenario) -> PredictViewState.Content {
            PredictFixtures.state(scenario, at: t0, context: testContext).content
        }
        for scenario in [PredictFixtures.Scenario.current, .currentWithoutReading, .clippedLow, .clippedHigh, .failingWithRun] {
            guard case .forecast = content(scenario) else { return XCTFail("\(scenario): \(content(scenario))") }
        }
        for scenario in [PredictFixtures.Scenario.stale, .aheadOfClock] {
            guard case .outOfDate = content(scenario) else { return XCTFail("\(scenario): \(content(scenario))") }
        }
        guard case .noRunYet = content(.noRunYet), case .waiting = content(.waiting), case .unavailable = content(.failingNothingHeld) else {
            return XCTFail("no-run, waiting, unavailable")
        }
        XCTAssertEqual(content(.notConfigured), .notConfigured)
        XCTAssertEqual(content(.turnedOff), .turnedOff(host: PredictFixtures.host))
        XCTAssertEqual(plain(PredictFixtures.state(.current, at: t0, context: testContext).forecast?.freshnessLine), "MODEL RAN 12:32 PM · 3 MIN AGO · FROM 105 AT 12:32 PM")
        XCTAssertEqual(plain(PredictFixtures.state(.currentWithoutReading, at: t0, context: testContext).forecast?.freshnessLine),
                       "MODEL RAN 12:32 PM · 3 MIN AGO")
        #endif
    }
}
