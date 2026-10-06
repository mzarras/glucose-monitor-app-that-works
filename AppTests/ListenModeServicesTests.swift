// D45 listen mode, D47 raw packet recording and the audit m1 backfill floor, in the live services
// (LiveAppServices+Connection.swift). Listen mode forces the Trio handoff and both uploaders off in
// the services: nothing is written to Trio's App Group and nothing is queued for upload, whatever
// the switches say (S6-style: the outputs are not even attached). Alerts stay on.

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
final class ListenModeServicesTests: XCTestCase {
    /// A persistence with listen mode saved, as a person who chose it before this launch.
    private func listeningPersistence(now: Date) throws -> LiveServicesHarness.Persistence {
        let persistence = LiveServicesHarness.Persistence(now: now)
        try persistence.connectionSettings.save(SensorConnectionSettings(mode: .listen, recordsRawGlucosePackets: false))
        return persistence
    }

    /// Nightscout and Dexcom Share switched on and fully configured (credentials in the harness's
    /// Keychain stand-in).
    private func configureUploads(_ persistence: LiveServicesHarness.Persistence) {
        let preferences = persistence.preferences
        preferences.nightscoutUploadEnabled = true
        preferences.nightscoutSiteURL = "https://ns.example.invalid"
        preferences.dexcomShareUploadEnabled = true
        preferences.dexcomShareReceiverSerial = "SM12345678"
    }

    private func storeUploadCredentials(_ harness: LiveServicesHarness) throws {
        try harness.credentials.write("token", for: .nightscoutToken)
        try harness.credentials.write("account", for: .dexcomShareAccountName)
        try harness.credentials.write("password", for: .dexcomSharePassword)
    }

    // MARK: - Trio (S6-style)

    func test_S6_listenModeWritesNothingToTriosAppGroup() async throws {
        let now = Date()
        let persistence = try listeningPersistence(now: now)
        let store = try XCTUnwrap(persistence.trioStore as? RecordingTrioStore)
        let harness = LiveServicesHarness(persistence, trioEnabled: true)
        let initialMode = await harness.sensor.mode
        XCTAssertEqual(initialMode, .listen, "the source is created in the saved mode")
        await harness.services.bootstrap()
        XCTAssertEqual(harness.services.connectionMode, .listen)
        XCTAssertTrue(harness.services.sharingOffWhileListening)
        XCTAssertTrue(harness.services.trio.offWhileListening)
        XCTAssertNil(harness.services.trioCoordinator.activeBridge, "the handoff is off whatever the switch says")

        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(120), at: now.addingTimeInterval(-600)))
        await harness.deliver(persistence.reading(.belowRange, at: now.addingTimeInterval(-300)))
        await harness.deliver(persistence.reading(.mgdl(50), at: now.addingTimeInterval(-10)))
        // Every other path that can reach Trio: foreground (retry, heartbeat), the bridge switch.
        await harness.services.handleForeground()
        harness.services.handleBackground()
        await harness.services.updateTrioHeartbeat()
        await harness.services.setTrioBridgeEnabled(false)
        await harness.services.setTrioBridgeEnabled(true)
        await harness.services.reseedTrio()

        XCTAssertEqual(store.writesOfAnyKey, 0, "nothing — readings, heartbeat keys, removals — is written to Trio's App Group while listening")
        XCTAssertTrue(store.payload.isEmpty)
        XCTAssertTrue(harness.isFiring(.urgentLow), "alerts stay on while listening")
        XCTAssertFalse(harness.isFiring(.trioBridge), "the handoff is off on purpose: no Trio alert")
        XCTAssertFalse(harness.services.trio.isFailing)
        XCTAssertEqual(harness.services.latestLiveReading?.value, .mgdl(50), "readings are stored and shown")
    }

    // MARK: - Uploads (S6-style)

    func test_S6_listenModeQueuesNothingForUpload() async throws {
        let now = Date()
        let persistence = try listeningPersistence(now: now)
        configureUploads(persistence)
        let transport = RecordingTransport()
        let harness = LiveServicesHarness(persistence, uploadTransport: transport)
        try storeUploadCredentials(harness)
        await harness.services.bootstrap()
        XCTAssertTrue(harness.services.uploads.activeUploaders.isEmpty, "no uploader exists while listening")
        XCTAssertTrue(harness.services.nightscout.upload.offWhileListening)
        XCTAssertTrue(harness.services.dexcomShare.upload.offWhileListening)

        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(130), at: now.addingTimeInterval(-10)))
        await harness.services.retryUploads()

        XCTAssertTrue(transport.requests.isEmpty, "nothing is sent")
        let queueFiles = (try? FileManager.default.contentsOfDirectory(atPath: persistence.directory.appendingPathComponent("Uploads").path)) ?? []
        XCTAssertTrue(queueFiles.isEmpty, "nothing is queued: \(queueFiles)")
        XCTAssertNil(harness.services.nightscout.upload.status)
        XCTAssertNil(harness.services.dexcomShare.upload.status)
        XCTAssertFalse(harness.services.nightscout.upload.isFailing)
        XCTAssertFalse(harness.services.dexcomShare.upload.isFailing)
    }

    // MARK: - Switching modes

    /// Pairing → listening → pairing at runtime: the source is switched and (for listen) started
    /// again with no code; Trio and uploads follow at once; the choice is saved for the next launch.
    func test_switchingModesRestartsTheSourceAndTheOutputsFollow() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        // Nightscout only: one POST per flush, so the request count is stable once it is seen.
        persistence.preferences.nightscoutUploadEnabled = true
        persistence.preferences.nightscoutSiteURL = "https://ns.example.invalid"
        let store = try XCTUnwrap(persistence.trioStore as? RecordingTrioStore)
        let transport = RecordingTransport()
        let harness = LiveServicesHarness(persistence, trioEnabled: true, uploadTransport: transport)
        try harness.credentials.write("token", for: .nightscoutToken)
        await harness.services.bootstrap()
        XCTAssertEqual(harness.services.connectionMode, .pair)
        XCTAssertTrue(harness.services.supportsCalibration)
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(120), at: now.addingTimeInterval(-10)))
        XCTAssertEqual(store.writesOfReadings, 1)
        await waitUntil("uploaded while pairing") { !transport.requests.isEmpty }

        // To listen mode.
        let startsBefore = harness.sensor.startCount
        try await harness.services.setConnectionMode(.listen)
        XCTAssertEqual(harness.sensor.modeHistory, [.listen])
        XCTAssertEqual(harness.sensor.startCount, startsBefore + 1, "listen mode is started at once, with no code")
        XCTAssertEqual(persistence.connectionSettings.load().settings.mode, .listen, "saved for the next launch")
        XCTAssertEqual(harness.services.connectionMode, .listen)
        XCTAssertFalse(harness.services.supportsCalibration)
        XCTAssertNil(harness.services.trioCoordinator.activeBridge)
        XCTAssertTrue(harness.services.uploads.activeUploaders.isEmpty)
        do {
            try await harness.services.pair(code: "1234")
            XCTFail("pairing does not exist in listen mode")
        } catch {
            XCTAssertEqual(error, .notAvailableInListenMode)
        }

        let trioWrites = store.writesOfAnyKey
        let requests = transport.requests.count
        persistence.clock.advance(by: 5 * 60)
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(50), at: persistence.clock.now.addingTimeInterval(-10)))
        await harness.services.retryUploads()
        XCTAssertEqual(store.writesOfAnyKey, trioWrites, "nothing reaches Trio while listening")
        XCTAssertEqual(transport.requests.count, requests, "nothing is uploaded while listening")
        XCTAssertTrue(harness.isFiring(.urgentLow), "alerts stay on")

        // Back to pairing: nothing is started without a code; the outputs are back.
        let startsInListen = harness.sensor.startCount
        try await harness.services.setConnectionMode(.pair)
        XCTAssertEqual(harness.sensor.modeHistory, [.listen, .primary(slot: .recommendedDefault)])
        XCTAssertEqual(harness.sensor.startCount, startsInListen, "pairing mode waits for pair(code:)")
        XCTAssertEqual(persistence.connectionSettings.load().settings.mode, .pair)
        XCTAssertNotNil(harness.services.trioCoordinator.activeBridge)
        XCTAssertEqual(harness.services.uploads.activeUploaders.count, 1)
        XCTAssertFalse(harness.services.trio.offWhileListening)
        XCTAssertTrue(harness.services.supportsCalibration)
    }

    /// A switch G7Kit refuses (its stored pairing cannot be deleted) changes nothing, also not the
    /// saved mode the next launch would use.
    func test_aRefusedSwitchChangesNothing() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let harness = LiveServicesHarness(persistence, trioEnabled: true)
        await harness.services.bootstrap()
        harness.sensor.setModeFails = true
        do {
            try await harness.services.setConnectionMode(.listen)
            XCTFail("the switch must report the failure")
        } catch {
            guard case .credentialStoreFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(harness.services.connectionMode, .pair)
        XCTAssertEqual(persistence.connectionSettings.load().settings.mode, .pair, "the saved mode is put back")
        XCTAssertTrue(harness.sensor.modeHistory.isEmpty)
        XCTAssertNotNil(harness.services.trioCoordinator.activeBridge)
    }

    /// The mode chosen in one process is the mode the next creates the source in — also when it is
    /// relaunched by Bluetooth before the first unlock, when the preferences are unreadable.
    func test_theSavedModeIsUsedAtTheNextLaunchBeforeTheFirstUnlock() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let first = LiveServicesHarness(persistence)
        await first.services.bootstrap()
        try await first.services.setConnectionMode(.listen)

        let relaunched = LiveServicesHarness(persistence, protectedData: false, launchedByBluetoothRestoration: true)
        let mode = await relaunched.sensor.mode
        XCTAssertEqual(mode, .listen, "created in listen mode: G7Kit would delete a listen pairing in primary mode")
        XCTAssertEqual(relaunched.services.connectionMode, .listen)
        await relaunched.services.bootstrap()
        XCTAssertFalse(relaunched.services.isBootstrapped, "still before the first unlock")
        XCTAssertTrue(relaunched.sensor.modeHistory.isEmpty, "never switched")
    }

    // MARK: - D47 raw packet recording

    func test_rawPacketRecordingIsPassedToTheSourceAndSaved() async throws {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        XCTAssertFalse(harness.services.recordsRawGlucosePackets, "off by default (D47)")
        XCTAssertFalse(persistence.connectionSettings.load().settings.g7Configuration.recordsRawGlucosePackets)

        await harness.services.setRecordsRawGlucosePackets(true)
        XCTAssertEqual(harness.sensor.recordingChanges, [true])
        XCTAssertTrue(harness.services.recordsRawGlucosePackets)
        XCTAssertTrue(persistence.connectionSettings.load().settings.g7Configuration.recordsRawGlucosePackets,
                      "the next launch creates the source with recording on")

        let relaunched = LiveServicesHarness(persistence)
        XCTAssertTrue(relaunched.services.recordsRawGlucosePackets)
        await relaunched.services.setRecordsRawGlucosePackets(false)
        XCTAssertEqual(relaunched.sensor.recordingChanges, [false])
        XCTAssertFalse(persistence.connectionSettings.load().settings.recordsRawGlucosePackets)
    }

    func test_connectionSettingsFileDefaultsAndRoundTrip() throws {
        let directory = PipelineFixtures.temporaryDirectory()
        let store = SensorConnectionSettingsStore(fileURL: directory.appendingPathComponent("SensorConnection.json"))
        XCTAssertEqual(store.load().settings, .defaults)
        XCTAssertNil(store.load().problem, "no file: a first launch, not a problem")
        XCTAssertEqual(SensorConnectionSettings.defaults.g7Mode, .primary(slot: .recommendedDefault))

        try store.save(SensorConnectionSettings(mode: .listen, recordsRawGlucosePackets: true))
        XCTAssertEqual(store.load().settings, SensorConnectionSettings(mode: .listen, recordsRawGlucosePackets: true))
        XCTAssertEqual(store.load().settings.g7Configuration.mode, .listen)

        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().settings, .defaults)
        XCTAssertNotNil(store.load().problem, "an unreadable file is logged")
    }

    // MARK: - Audit m1: G7Kit's backfill floor from the production store

    /// Readings delivered while the store failed are held in memory; the app is terminated and they
    /// are lost. At the next launch G7Kit's floor is the latest reading actually stored, so the
    /// sensor's backfill of the lost ones is published again (and stored, dedupe by id).
    func test_S5_backfillFloorIsTheLatestStoredReadingAfterHeldReadingsWereLost() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let serial = PipelineFixtures.serial

        // Process 1: the store works; A is stored and becomes the floor.
        let first = LiveServicesHarness(persistence)
        await first.services.bootstrap()
        await first.deliver(state: first.activeState)
        let stored = persistence.reading(.mgdl(120), at: now.addingTimeInterval(-10 * 60))
        await first.deliver(stored)
        await waitUntil("floor after the write") { first.sensor.latestStoredReadingCalls.last?.reading?.id == stored.id }
        XCTAssertEqual(first.sensor.latestStoredReadingCalls.last?.serial, serial)

        // Process 2: the store cannot open; B and C are held (alerts and Trio had them), then the
        // process is terminated.
        persistence.clock.set(now)
        let second = LiveServicesHarness(persistence, storeOpens: false)
        await second.services.bootstrap()
        await second.deliver(state: second.activeState)
        let lostB = persistence.reading(.mgdl(118), at: now.addingTimeInterval(-5 * 60))
        let lostC = persistence.reading(.mgdl(116), at: now.addingTimeInterval(-10))
        await second.deliver(lostB)
        await second.deliver(lostC)
        XCTAssertEqual(second.services.sensorPipeline.heldReadingCount, 2)
        XCTAssertTrue(second.sensor.latestStoredReadingCalls.isEmpty, "no floor without a readable store")

        // Process 3: the store opens; the floor is A, the latest reading actually stored.
        persistence.clock.advance(by: 60)
        let third = LiveServicesHarness(persistence)
        await third.services.bootstrap()
        await waitUntil("floor at launch") { !third.sensor.latestStoredReadingCalls.isEmpty }
        let floor = try XCTUnwrap(third.sensor.latestStoredReadingCalls.last)
        XCTAssertEqual(floor.reading?.id, stored.id, "the floor is the latest stored reading, not the lost ones")
        XCTAssertEqual(floor.serial, serial)

        // The sensor backfills B and C again (same id and date, isBackfill): stored, floor moves up.
        await third.deliver(state: third.activeState)
        await third.deliver(persistence.reading(.mgdl(118), at: lostB.date, backfill: true))
        await third.deliver(persistence.reading(.mgdl(116), at: lostC.date, backfill: true))
        await waitUntil("floor follows the recovered readings") { third.sensor.latestStoredReadingCalls.last?.reading?.id == lostC.id }
        let recovered = try await XCTUnwrap(third.services.productionStore).readings(from: now.addingTimeInterval(-3_600), to: now.addingTimeInterval(120))
        XCTAssertEqual(recovered.map(\.id), [stored.id, lostB.id, lostC.id])
    }
}
