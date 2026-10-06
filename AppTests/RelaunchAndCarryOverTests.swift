import GlucoseCore
import WidgetCore
import XCTest
@testable import Sensor

/// Phase 3: app killed and relaunched (restored UI state; nothing stale shown as current at launch),
/// and the Phase 2 carry-overs (AGP flag markers, Trio held back, the DEBUG replay clock).
@MainActor
final class RelaunchAndCarryOverTests: XCTestCase {
    private func launch(_ services: PreviewAppServices, preferences: AppUIPreferences, arguments: [String] = [], clock: (@MainActor () -> Date)? = { t0 }) -> AppModel {
        AppModel.launch(services: services, arguments: arguments, preferences: preferences, calendar: utcCalendar, clock: clock,
                        protectedDataAvailable: { true })
    }

    private func preferences() -> AppUIPreferences {
        let preferences = AppUIPreferences(defaults: UserDefaults(suiteName: "Relaunch.\(UUID().uuidString)")!)
        preferences.onboardingCompleted = true
        return preferences
    }

    /// The selected tab, Trends period and appearance come back after the app is killed; an explicit
    /// `-tab` launch argument wins.
    func test_uiStateIsRestoredAfterRelaunch() async {
        let services = PreviewAppServices(readings: series(from: t0.addingTimeInterval(-40 * 86_400), to: t0) { _ in .mgdl(120) }, sensorState: activeSensor)
        let stored = preferences()
        let first = launch(services, preferences: stored)
        first.apply(.sensor)
        first.selectTab(.trends)
        first.selectTrendsPeriod(.thirtyDays)
        first.setAppearance(.dark)
        await first.settle()

        let relaunched = launch(services, preferences: stored)
        relaunched.apply(.sensor)
        await relaunched.settle()
        XCTAssertEqual(relaunched.selectedTab, .trends)
        XCTAssertEqual(relaunched.trends.period, .thirtyDays)
        XCTAssertEqual(relaunched.settings.appearance, .dark)
        XCTAssertNotNil(relaunched.trends.timeInRange, "the restored period's statistics are computed")

        let withArgument = launch(services, preferences: stored, arguments: ["-tab", "now"])
        XCTAssertEqual(withArgument.selectedTab, .now)
    }

    /// At launch, before the source's first state, nothing shows a stored value as current:
    /// "Starting up"; once the state arrives, a 3-hour-old reading is a message, never a number.
    func test_nothingStaleShowsAsCurrentAtLaunch() {
        let old = sensorReading(t0.addingTimeInterval(-3 * 3_600), .mgdl(140))
        let services = PreviewAppServices(readings: [old], sensorState: .notPaired)
        services.latestLiveReading = old
        let model = launch(services, preferences: preferences())
        guard case .message(let title, _, let action) = NowHero.make(model.now.display(now: t0), now: t0, sensorStateKnown: model.now.sensorStateKnown) else {
            return XCTFail("no number at launch")
        }
        XCTAssertEqual(title, "Starting up")
        XCTAssertNil(action)
        services.sensorState = activeSensor
        model.apply(.sensor)
        guard case .message(let later, _, _) = NowHero.make(model.now.display(now: t0), now: t0, sensorStateKnown: model.now.sensorStateKnown) else {
            return XCTFail("a 3-hour-old reading is never shown as current")
        }
        XCTAssertEqual(later, "No recent readings")
    }

    // MARK: - Carry-overs

    /// AGP: a "HIGH"/"LOW" label at the start of each run of buckets whose 95th/5th percentile is the
    /// sensor's flag (S4); runs break at gaps over an hour.
    func test_agpFlagMarkers() {
        func bucket(_ minute: Int, p5: AGPLineValue = .mgdl(80), p95: AGPLineValue = .mgdl(180)) -> AGPBucket {
            AGPBucket(minuteOfDay: minute, p5: p5, p25: .mgdl(100), p50: .mgdl(120), p75: .mgdl(140), p95: p95)
        }
        let buckets = [
            bucket(0), bucket(15, p95: .aboveRange), bucket(30, p95: .aboveRange), bucket(45),
            bucket(60, p5: .belowRange), bucket(75, p5: .belowRange),
            bucket(240, p95: .aboveRange), // after a gap: a new run
        ]
        XCTAssertEqual(AGPFlagMarkers.runs(buckets), [
            AGPFlagMarkers.Marker(minuteOfDay: 15, isHigh: true),
            AGPFlagMarkers.Marker(minuteOfDay: 60, isHigh: false),
            AGPFlagMarkers.Marker(minuteOfDay: 240, isHigh: true),
        ])
        XCTAssertEqual(AGPFlagMarkers.runs([bucket(0), bucket(15)]), [])
    }

    /// Settings › Trio says how many readings wait for the launch re-seed, and since when.
    func test_trioHeldBackReadings() {
        var summary = TrioBridgeSummary.off
        summary.isEnabled = true
        summary.liveOutputsAllowed = true
        summary.appGroupID = "group.trio"
        summary.heldBackReadings = 3
        summary.heldBackSince = t0
        let trio = SettingsMapping.trio(summary, now: t0)
        XCTAssertEqual(trio.heldBackReadings, 3)
        XCTAssertEqual(SettingsText.trioHeldBack(trio, context: testContext),
                       "3 readings held back since \(TimeText.time(t0, testContext)), until Trio's App Group is brought up to date.")
        summary.heldBackReadings = 0
        XCTAssertNil(SettingsText.trioHeldBack(SettingsMapping.trio(summary, now: t0)))
    }

    /// DEBUG: during a replay run the UI's clock is the replay clock (accelerated replays keep up);
    /// otherwise the phone clock.
    func test_replayClockDrivesTheUIClockInDebug() {
        let services = PreviewAppServices(sensorState: activeSensor)
        let model = launch(services, preferences: preferences(), clock: nil)
        XCTAssertLessThan(abs(model.clock().timeIntervalSinceNow), 1, "no replay: the phone clock")
        let ahead = Date().addingTimeInterval(6 * 3_600)
        services.replayClockNow = ahead
        XCTAssertEqual(model.clock(), ahead)
        services.replayClockNow = nil
        XCTAssertLessThan(abs(model.clock().timeIntervalSinceNow), 1)
    }
}
