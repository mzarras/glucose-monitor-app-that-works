import XCTest
import GlucoseCore
@testable import AlertEngine

final class AlertTextTests: XCTestCase {
    private func context(
        reading: LiveReadingSummary? = nil, settled: SensorState? = nil, reported: SensorState? = nil, bridge: TrioBridgeStatus = .off
    ) -> AlertTextContext {
        AlertTextContext(reading: reading, lastValidReadingDate: nil, settings: .defaults, settledSensorState: settled,
                         lastReportedSensorState: reported, bridgeStatus: bridge, calendar: Fixtures.utc,
                         locale: Locale(identifier: "en_US_POSIX"))
    }

    func test_everyAlertHasADistinctTitleAndABody() {
        let titles = AlertKind.allCases.map(AlertText.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        for kind in AlertKind.allCases {
            XCTAssertFalse(AlertText.body(kind, context: context(), isRepeat: false).isEmpty, "\(kind)")
        }
    }

    func test_S4_flagsAreWrittenAsFlags() {
        XCTAssertEqual(AlertText.valueText(.belowRange), "LOW (below sensor range)")
        XCTAssertEqual(AlertText.valueText(.aboveRange), "HIGH (above sensor range)")
        XCTAssertEqual(AlertText.valueText(.mgdl(52)), "52 mg/dL")
        let low = LiveReadingSummary(id: "x", date: Fixtures.t0, value: .belowRange, trendRate: nil)
        XCTAssertEqual(AlertText.body(.urgentLow, context: context(reading: low), isRepeat: false), "LOW (below sensor range) at 12:00 PM. Treat now.")
    }

    func test_S1_everyValueCarriesItsMeasurementTime() {
        let r = LiveReadingSummary(id: "x", date: Fixtures.t0, value: .mgdl(64), trendRate: -1)
        XCTAssertEqual(AlertText.body(.low, context: context(reading: r), isRepeat: false), "64 mg/dL at 12:00 PM.")
        XCTAssertEqual(AlertText.body(.urgentLow, context: context(reading: r), isRepeat: true), "Not acknowledged. Last reading 64 mg/dL at 12:00 PM.")
        XCTAssertEqual(AlertText.body(.urgentLow, context: context(), isRepeat: false), "No recent reading. Treat now.")
    }

    func test_rateIsWrittenExactlyAsReported() {
        XCTAssertEqual(AlertText.rateText(-2.04), "falling 2.0 mg/dL/min")
        XCTAssertEqual(AlertText.rateText(3.26), "rising 3.3 mg/dL/min")
        XCTAssertEqual(AlertText.rateText(0), "steady")
        XCTAssertEqual(AlertText.rateText(nil), "trend not reported")
        XCTAssertEqual(AlertText.rateText(.infinity), "trend not reported")
    }

    func test_statusBodiesFallBackWhenTheStateHasMoved() {
        XCTAssertEqual(AlertText.body(.sensorExpiringIn24Hours, context: context(), isRepeat: false), "Plan a sensor change.")
        XCTAssertEqual(AlertText.body(.sensorExpiringIn12Hours, context: context(), isRepeat: false), "Plan a sensor change.")
        XCTAssertEqual(AlertText.body(.sensorExpiringIn2Hours, context: context(), isRepeat: false), "Plan a sensor change.")
        XCTAssertEqual(AlertText.body(.sensorGracePeriod, context: context(), isRepeat: false), "Replace the sensor soon.")
        XCTAssertEqual(AlertText.title(.sensorExpiringIn12Hours, context: context()), "Sensor expires within 12 hours")
        XCTAssertEqual(AlertText.title(.sensorGracePeriod, context: context()), "Sensor session ended — grace period")
        XCTAssertEqual(AlertText.body(.sensorFailed, context: context(), isRepeat: false), "Readings have stopped.")
        XCTAssertEqual(AlertText.body(.sensorError, context: context(), isRepeat: false), "The sensor reported an error.")
        XCTAssertEqual(AlertText.body(.bluetoothUnavailable, context: context(), isRepeat: false), "No readings can arrive.")
        XCTAssertEqual(AlertText.body(.bluetoothUnavailable, context: context(reported: .bluetoothUnavailable(.resetting)), isRepeat: false),
                       "Bluetooth is restarting.")
        XCTAssertEqual(AlertText.body(.trioBridge, context: context(bridge: .healthy), isRepeat: false), "Trio is not receiving readings.")
        XCTAssertEqual(AlertText.body(.sensorExpired, context: context(), isRepeat: false), "The session has ended. No readings until a new sensor is paired.")
        XCTAssertEqual(AlertText.body(.sensorWarmUpComplete, context: context(), isRepeat: false), "Warm-up is complete. Readings are starting.")
        XCTAssertEqual(AlertText.body(.calibrationNeeded, context: context(), isRepeat: false), "The sensor needs a calibration.")
        XCTAssertEqual(AlertText.body(.storageFailing, context: context(), isRepeat: false),
                       "Readings could not be saved on the phone. Alerts and Trio still get them; history and charts will have a gap. Check free storage.")
        XCTAssertEqual(AlertText.title(.sensorFailed, context: context()), "Sensor failed", "without a failure state: the list name")
    }

    /// D43: the expiry reminders state the time left, to the minute, and the day as seen from delivery.
    func test_durationsAndDays() {
        XCTAssertEqual(AlertText.duration(24 * 3600), "24 hours")
        XCTAssertEqual(AlertText.duration(3600), "1 hour")
        XCTAssertEqual(AlertText.duration(20 * 3600 + 15 * 60 + 20), "20 h 15 min")
        XCTAssertEqual(AlertText.duration(45 * 60), "45 minutes")
        XCTAssertEqual(AlertText.duration(60), "1 minute")
        XCTAssertEqual(AlertText.duration(20), "less than a minute")
        XCTAssertEqual(AlertText.duration(-5), "less than a minute")
        XCTAssertEqual(AlertText.shortDuration(12 * 3600), "12 h")
        XCTAssertEqual(AlertText.shortDuration(9 * 3600 + 20 * 60), "9 h 20 min")
        XCTAssertEqual(AlertText.shortDuration(45 * 60), "45 min")
        let c = context()
        XCTAssertEqual(AlertText.day(Fixtures.t0.addingTimeInterval(11 * 3600), from: Fixtures.t0, c), "today")
        XCTAssertEqual(AlertText.day(Fixtures.t0.addingTimeInterval(13 * 3600), from: Fixtures.t0, c), "tomorrow")
        XCTAssertEqual(AlertText.day(Fixtures.t0.addingTimeInterval(2 * 86_400), from: Fixtures.t0, c), "on Sep 25, 2026")
    }

    func test_aGracePeriodThatIsNotWholeHoursIsWrittenInHoursAndMinutes() {
        var c = context()
        c.deliveredAt = Fixtures.t0
        c.sessionExpiresAt = Fixtures.t0
        c.graceEndsAt = Fixtures.t0.addingTimeInterval(12 * 3600 + 30 * 60)
        XCTAssertEqual(AlertText.title(.sensorGracePeriod, context: c), "Sensor session ended — 12 h 30 min grace period")
        XCTAssertEqual(AlertText.body(.sensorExpiringIn2Hours, context: c, isRepeat: false), "Plan a sensor change. A 12 h 30 min grace period follows.")
    }

    func test_kindProperties() {
        XCTAssertEqual(AlertKind.urgentLow.priority, 0)
        XCTAssertTrue(AlertKind.allCases.allSatisfy { $0.priority < AlertKind.allCases.count })
        XCTAssertEqual(AlertKind.allCases.filter(\.isGlucoseAlert), [.urgentLow, .urgentLowSoon, .low, .high, .fallingFast, .risingFast])
        XCTAssertEqual(AlertKind.allCases.filter(\.usesScheduledNotifications), [.urgentLow, .missedReadings])
        XCTAssertEqual(AlertKind.sensorExpiryReminders,
                       [.sensorExpiringIn24Hours, .sensorExpiringIn12Hours, .sensorExpiringIn2Hours, .sensorGracePeriod, .sensorExpired])
        XCTAssertEqual(AlertKind.allCases.filter(\.isEventAlert),
                       [.sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn12Hours, .sensorExpiringIn2Hours, .sensorGracePeriod])
    }
}
