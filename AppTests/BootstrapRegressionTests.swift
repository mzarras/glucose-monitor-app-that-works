// Regression tests adopted from the Phase 2 follow-up safety review's probe (FU-B, blocker B1):
// they failed on 1323698 (the clock-mismatch latch was cleared on every relaunch) and pass on the
// base 3517554 and on the fix. Real `LiveAppServices` and `G7CGMSource` (no Bluetooth in the
// simulator), a temporary production database seeded with R, the latch persisted for R.

import AlertEngine
import Foundation
import G7Kit
import GlucoseCore
import GlucoseStore
import NightscoutKit
import TrioBridge
import XCTest
@testable import Sensor

@MainActor
final class BootstrapRegressionTests: XCTestCase {
    /// 2b: a clock-mismatch latch persisted by the previous process for the latest stored reading R
    /// (the phone clock has since passed R's date, no newer reading yet) must survive a relaunch
    /// bootstrap.
    func test_S1_clockMismatchLatchSurvivesBootstrap() async throws {
        let dir = PipelineFixtures.temporaryDirectory()
        let dbURL = dir.appendingPathComponent("GlucoseStore/readings.sqlite")
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        let serial = "REGRG7-FUB"
        let rDate = now.addingTimeInterval(-120)
        let r = GlucoseReading(
            id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: 200_000), date: rDate, value: .mgdl(120),
            trendRate: 0, isBackfill: false, source: .sensor, sensorSerial: serial
        )
        do {
            let seed = try await GlucoseStore.production(at: dbURL)
            let stored = try await seed.insert([r])
            XCTAssertEqual(stored.count, 1)
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "bootstrap-regression-\(UUID().uuidString)"))
        let preferences = AppPreferences(defaults: defaults)
        preferences.clockMismatch = ClockMismatchState(latchedFor: rDate, lastCheckWallClock: nil, lastCheckUptime: nil)

        let diagnostics = RingBufferDiagnosticLog(fileURL: nil)
        let g7 = G7CGMSource(
            configuration: G7Configuration(restoreIdentifier: "bootstrap.regression.\(UUID().uuidString)"),
            credentialStore: G7InMemoryCredentialStore(), diagnostics: diagnostics
        )
        let services = LiveAppServices(LiveAppServices.Dependencies(
            g7: g7, diagnostics: diagnostics, preferences: preferences, credentials: InMemoryCredentialStore(),
            trio: TrioCoordinator(appGroupID: nil, store: nil, diagnostics: diagnostics),
            uploads: UploadCoordinator(credentials: InMemoryCredentialStore(), queueDirectory: dir.appendingPathComponent("Uploads"),
                                       deviceName: "Test", transport: NeverCalledTransport(), diagnostics: diagnostics),
            alertPorts: AppEnvironment.makeAlertPorts(arguments: ["-silenceAlertAudio"], diagnostics: diagnostics),
            widget: nil, databaseURL: dbURL, httpTransport: NeverCalledTransport(), launchReplay: nil
        ))

        await services.bootstrap()
        await waitUntil("store open and pipeline idle") {
            services.productionStore != nil && services.sensorPipeline.isIdle && services.sensorPipeline.completedDrainCount >= 1
        }
        // Let the drain the attach signalled, and the attach's own refresh, finish.
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(500))
        services.updateClockMismatchLatch(now: Date())

        XCTAssertEqual(services.latestLiveReading?.id, r.id, "R is the latest live reading after the store opened")
        XCTAssertEqual(services.clockMismatchLatchedFor, rDate, "the latch for R must survive the relaunch")
        XCTAssertEqual(preferences.clockMismatch.latchedFor, rDate, "and stay persisted")
    }

    /// 2b: the launch re-seed hands older stored readings to a bridge that already published a newer
    /// held reading. The payload's newest element must stay the newer reading (no move backwards).
    func test_trioReseedAfterAHeldReadingKeepsTheNewestFirst() async throws {
        let store = RecordingTrioStore()
        let trio = TrioCoordinator(appGroupID: "group.org.nightscout.ABCDE12345.trio.trio-app-group", store: store, diagnostics: NullDiagnosticLog(),
                                   clock: { PipelineFixtures.start })
        trio.configure(enabled: true, liveOutputsAllowed: true)
        let bridge = try XCTUnwrap(trio.activeBridge)
        let start = PipelineFixtures.start
        let newest = PipelineFixtures.reading(.mgdl(150), at: start.addingTimeInterval(-10))
        await bridge.publish([newest], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 150)
        let older = (1...20).map { PipelineFixtures.reading(.mgdl(100), at: start.addingTimeInterval(TimeInterval(-300 * $0 - 10))) }
        await trio.reseed(with: older + [newest], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.count, 21)
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 150, "newest stays first")
        // A re-seed with a stale imported/replay copy never reaches Trio (S6).
        let imported = PipelineFixtures.imported(.mgdl(60), at: start.addingTimeInterval(-5))
        await trio.reseed(with: [imported], session: PipelineFixtures.session)
        XCTAssertEqual(store.payload.first?["Value"] as? Int, 150)
        XCTAssertEqual(store.payload.count, 21)
    }
}
