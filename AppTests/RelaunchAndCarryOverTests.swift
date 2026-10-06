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

    /// The Trends period and appearance come back after the app is killed; the tab does not: a cold
    /// launch opens Now (review m6: a notification or widget tap lands on the current reading); an
    /// explicit `-tab` launch argument picks another.
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
        XCTAssertEqual(relaunched.selectedTab, .now, "a cold launch opens Now")
        XCTAssertEqual(relaunched.trends.period, .thirtyDays)
        XCTAssertEqual(relaunched.settings.appearance, .dark)
        relaunched.selectTab(.trends)
        await relaunched.settle()
        XCTAssertEqual(relaunched.trends.period, .thirtyDays)
        XCTAssertNotNil(relaunched.trends.timeInRange, "the restored period's statistics are computed when Trends opens")

        let withArgument = launch(services, preferences: stored, arguments: ["-tab", "alerts"])
        XCTAssertEqual(withArgument.selectedTab, .alerts)
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

    /// Audit m18: the import's future-dated count reaches the screen whichever field carries it
    /// (`rejectedFutureDated` from a Clarity parse, `skipped["futureDated"]` from Nightscout), is not
    /// counted again as a skipped entry, and is worded for the person.
    func test_importFutureDatedReadingsAreShown() {
        func state(rejected: Int, skipped: [String: Int]) -> HistoryImportState {
            HistoryImportState(origin: .nightscout, phase: .finished, readingsImported: 500, readingsSkippedByStore: 0,
                               coveredFrom: t0.addingTimeInterval(-86_400), coveredTo: t0, skipped: skipped,
                               rejectedFutureDated: rejected, startedAt: t0, finishedAt: t0)
        }
        let nightscout = OnboardingMapping.importProgress(state(rejected: 0, skipped: ["futureDated": 4, "errorCode": 2]))
        XCTAssertEqual(nightscout?.rejectedFutureDated, 4)
        XCTAssertEqual(nightscout?.skippedNote, "2 entries skipped", "future-dated readings are not also \"skipped entries\"")
        XCTAssertEqual(OnboardingMapping.importProgress(state(rejected: 3, skipped: [:]))?.rejectedFutureDated, 3)
        XCTAssertEqual(OnboardingMapping.importProgress(state(rejected: 3, skipped: ["futureDated": 3]))?.rejectedFutureDated, 3, "not doubled")
        XCTAssertNil(OnboardingMapping.importProgress(state(rejected: 0, skipped: [:]))?.skippedNote)

        XCTAssertNil(OnboardingText.futureDatedNote(0))
        XCTAssertEqual(OnboardingText.futureDatedNote(1), "1 reading was dated in the future and left out. Check the time zone chosen for the import.")
        XCTAssertEqual(OnboardingText.futureDatedNote(4), "4 readings were dated in the future and left out. Check the time zone chosen for the import.")
    }

    /// Phase 3 copy fixes: Trio has no screen showing its App Group (only glucose notifications with
    /// "Add Glucose Source to Alarm", and the CGM screen's "CGM address :" heartbeat line); the
    /// diagnostics export says exactly what it holds; urgent low says it rings at snooze end (D44).
    func test_phase3Copy() {
        XCTAssertFalse(SettingsText.trioAppGroupHelp.contains("App Info"), "no such Trio screen")
        XCTAssertTrue(SettingsText.trioAppGroupHelp.contains("Add Glucose Source to Alarm"))
        XCTAssertTrue(SettingsText.trioAppGroupHelp.contains("CGM address :"))
        for item in ["serial", "Nightscout host name", "glucose values", "No passwords, tokens or pairing codes"] {
            XCTAssertTrue(SettingsText.diagnosticsContents.contains(item), item)
        }
        XCTAssertFalse(SettingsText.diagnosticsContents.contains("no personal data"))
        XCTAssertTrue(AlertsText.urgentLowNote.contains("When the snooze ends it rings again"))
    }
}
