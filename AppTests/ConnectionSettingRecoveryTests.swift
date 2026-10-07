// Phase 3b review follow-ups for the sensor connection setting (D45):
// - m2: an unreadable SensorConnection.json never switches modes; the source stays stopped, a banner
//   asks the person to choose Listen or Pair again, and that choice rewrites the file.
// - m3: a failed switch whose rollback cannot be saved is surfaced the same way, and the source is
//   not started until the person chooses.
// - m2/m3: G7Kit cannot delete the pairing record unless the person asked (GuardedG7CredentialStore),
//   proven against the real G7CGMSource.
// - m1: switching from pairing to listen mode removes this app's readings and heartbeat keys from
//   Trio's App Group.

import AlertEngine
import Foundation
import G7Kit
import GlucoseCore
import TrioBridge
import XCTest
@testable import Sensor

@MainActor
final class ConnectionSettingRecoveryTests: XCTestCase {
    private func writeFile(_ text: String, _ persistence: LiveServicesHarness.Persistence) throws {
        let url = persistence.connectionSettings.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func fileText(_ persistence: LiveServicesHarness.Persistence) -> String? {
        (try? Data(contentsOf: persistence.connectionSettings.fileURL)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func bannerKinds(_ model: AppModel, _ persistence: LiveServicesHarness.Persistence) -> Set<AppBanner.Kind> {
        Set(model.now.banners(now: persistence.clock.now).map(\.kind))
    }

    private func launchModel(_ harness: LiveServicesHarness) -> AppModel {
        let preferences = AppUIPreferences(defaults: UserDefaults(suiteName: "connection-\(UUID().uuidString)")!)
        preferences.onboardingCompleted = true
        preferences.connectionModeChosen = true
        let clock = harness.persistence.clock
        return AppModel.launch(services: harness.services, arguments: [], preferences: preferences,
                               clock: { clock.now }, protectedDataAvailable: { true })
    }

    // MARK: - m2: an unreadable mode file

    func test_S5_unreadableModeFileOnAListeningPhoneKeepsTheSourceStoppedAndAsksAgain() async throws {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        // A listening phone whose file was cut short (a crash mid-write, a restore from backup).
        let corrupt = "{\"mode\":\"lis"
        try writeFile(corrupt, persistence)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        await harness.services.handleForeground()
        harness.services.handleBackground()
        harness.services.protectedDataDidBecomeAvailable()
        await harness.services.setRecordsRawGlucosePackets(true)

        XCTAssertNotNil(harness.services.connectionSettingProblem)
        XCTAssertEqual(harness.sensor.startCount, 0, "never started on a setting that can't be read")
        XCTAssertTrue(harness.sensor.modeHistory.isEmpty, "no mode switch")
        XCTAssertEqual(fileText(persistence), corrupt, "the file is not rewritten with a mode nobody chose")

        let model = launchModel(harness)
        await waitUntil("banner") { self.bannerKinds(model, persistence).contains(.connectionSettingUnreadable) }
        XCTAssertNil(model.settings.connection?.mode, "Settings asks for a choice rather than showing pairing mode")

        // The person chooses Listen: the file is rewritten, the source switched and started.
        model.setConnectionMode(.listen)
        await waitUntil("resolved") { harness.services.connectionSettingProblem == nil && harness.sensor.startCount == 1 }
        XCTAssertEqual(persistence.connectionSettings.load(), .loaded(SensorConnectionSettings(mode: .listen, recordsRawGlucosePackets: true)))
        XCTAssertEqual(harness.sensor.modeHistory, [.listen])
        await waitUntil("banner gone") { !self.bannerKinds(model, persistence).contains(.connectionSettingUnreadable) }
        XCTAssertEqual(model.settings.connection?.mode, .listen)
    }

    /// Choosing the mode the source happens to be in still records the choice and starts it (the
    /// UI's "same mode" shortcut does not apply while the setting is unresolved).
    func test_choosingTheShownModeAfterAnUnreadableFileRewritesItAndStarts() async throws {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        try writeFile("not json", persistence)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        XCTAssertEqual(harness.services.connectionMode, .pair, "the source was created in the defaults")
        let model = launchModel(harness)

        model.setConnectionMode(.pair)
        await waitUntil("resolved") { harness.services.connectionSettingProblem == nil && harness.sensor.startCount == 1 }
        XCTAssertEqual(persistence.connectionSettings.load(), .loaded(.defaults), "rewritten")
        XCTAssertTrue(harness.sensor.modeHistory.isEmpty, "already in pairing mode: no switch, the stored pairing resumes")
    }

    func test_unknownModeStringIsUnreadable() throws {
        let store = SensorConnectionSettingsStore(fileURL: PipelineFixtures.temporaryDirectory().appendingPathComponent("SensorConnection.json"))
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"mode\":\"follow\",\"recordsRawGlucosePackets\":false}".utf8).write(to: store.fileURL)
        guard case .unreadable(let reason) = store.load() else { return XCTFail("an unknown mode is not a choice: \(store.load())") }
        XCTAssertTrue(reason.contains("follow"), reason)
        XCTAssertEqual(store.load().settings, .defaults, "the source is created in the defaults (and not started)")
    }

    func test_aMissingFileIsAFirstLaunchNotAProblem() async {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        XCTAssertEqual(persistence.connectionSettings.load(), .missing)
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        XCTAssertNil(harness.services.connectionSettingProblem)
        XCTAssertGreaterThanOrEqual(harness.sensor.startCount, 1)
    }

    // MARK: - m3: a failed switch whose rollback can't be saved

    func test_S5_failedSwitchWhoseRollbackCannotBeSavedIsSurfacedAndNothingStarts() async throws {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        // The first write (the new mode) succeeds; later ones fail (the disk filled up) until it recovers.
        let writes = CallCounter()
        let diskFull = LiveServicesHarness.Flag(true)
        persistence.settingsWrite = { data, url in
            if writes.next() > 1, diskFull.value { throw CocoaError(.fileWriteOutOfSpace) }
            try SensorConnectionSettingsStore.writeAtomically(data, to: url)
        }
        let harness = LiveServicesHarness(persistence)
        await harness.services.bootstrap()
        let starts = harness.sensor.startCount
        harness.sensor.setModeFails = true

        do {
            try await harness.services.setConnectionMode(.listen)
            XCTFail("the switch must report the failure")
        } catch {
            guard case .credentialStoreFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(writes.value, 1 + LiveAppServices.restoreAttempts, "the rollback is retried")
        XCTAssertNotNil(harness.services.connectionSettingProblem, "surfaced")
        XCTAssertEqual(persistence.connectionSettings.load().settings.mode, .listen, "the file is left wrong…")
        XCTAssertEqual(harness.services.connectionMode, .pair, "…but the services did not switch")

        // Not started again — not by a foreground, not by the unlock — until the person chooses.
        await harness.services.handleForeground()
        harness.services.handleBackground()
        harness.services.protectedDataDidBecomeAvailable()
        XCTAssertEqual(harness.sensor.startCount, starts)
        let model = launchModel(harness)
        await waitUntil("banner") { self.bannerKinds(model, persistence).contains(.connectionSettingUnreadable) }

        // The disk recovers; the person chooses Pair again: rewritten, resumed.
        diskFull.value = false
        harness.sensor.setModeFails = false
        model.setConnectionMode(.pair)
        await waitUntil("resolved") { harness.services.connectionSettingProblem == nil && harness.sensor.startCount == starts + 1 }
        XCTAssertEqual(persistence.connectionSettings.load(), .loaded(.defaults))
    }

    // MARK: - m2/m3: G7Kit deletes a pairing only when asked (real G7CGMSource)

    private func listenRecord() -> G7PairingRecord {
        var record = G7PairingRecord.forListening()
        record.serial = "DXCM12-0A0B0C0D"
        record.peripheralIdentifier = UUID()
        record.sensorName = "DXCM12"
        return record
    }

    private func makeSource(_ mode: G7ConnectionMode, store: any G7CredentialStore) -> G7CGMSource {
        G7CGMSource(
            configuration: G7Configuration(restoreIdentifier: "com.mzarras.sensor.tests.\(UUID().uuidString)", mode: mode),
            credentialStore: store, diagnostics: NullDiagnosticLog()
        )
    }

    /// A listening phone whose mode file could not be read: the source is created in the default
    /// pairing mode. Unguarded, G7Kit drops the listen record right there; guarded, it is kept.
    func test_S5_aSourceCreatedInTheWrongModeCannotDeleteThePairing() async throws {
        let unguarded = G7InMemoryCredentialStore(listenRecord())
        _ = makeSource(.primary(slot: .recommendedDefault), store: unguarded)
        XCTAssertNil(try unguarded.load(), "the hazard: G7Kit drops a pairing of the other mode at creation")

        let inner = G7InMemoryCredentialStore(listenRecord())
        let guarded = GuardedG7CredentialStore(wrapping: inner)
        let source = makeSource(.primary(slot: .recommendedDefault), store: guarded)
        XCTAssertEqual(try inner.load()?.isListenRecord, true, "kept")
        XCTAssertNotNil(guarded.refusedDeletion, "and reported, for the services' banner")
        do {
            try await source.start(pairingCode: nil)
            XCTFail("a start in the wrong mode must not proceed")
        } catch {}
        XCTAssertEqual(try inner.load()?.isListenRecord, true, "still kept after a start")

        // The person chooses: now G7Kit may switch and drop it.
        try await guarded.allowingDeletion { try await source.setMode(.listen) }
        XCTAssertNil(try inner.load())
        guarded.clearRefusal()
        XCTAssertNil(guarded.refusedDeletion)
    }

    /// The services report a refused deletion as the connection-setting problem and keep the source
    /// stopped (a file left naming the wrong mode after m3, read at the next launch).
    func test_S5_aRefusedDeletionAtLaunchIsSurfacedAndStopsTheSource() async throws {
        let inner = G7InMemoryCredentialStore(listenRecord())
        let guarded = GuardedG7CredentialStore(wrapping: inner)
        XCTAssertThrowsError(try guarded.delete())
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let harness = LiveServicesHarness(persistence, credentialGuard: guarded)
        await harness.services.bootstrap()
        XCTAssertNotNil(harness.services.connectionSettingProblem)
        XCTAssertEqual(harness.sensor.startCount, 0)

        try await harness.services.setConnectionMode(.listen)
        XCTAssertNil(harness.services.connectionSettingProblem)
        XCTAssertNil(guarded.refusedDeletion)
        XCTAssertEqual(harness.sensor.startCount, 1)
    }

    /// Forget is the person's own action: the pairing is deleted (through the guard).
    func test_forgetDeletesThePairingThroughTheGuard() async throws {
        var primary = G7PairingRecord(pairingCode: "1234", slot: .recommendedDefault)
        primary.serial = "DXCM12-0A0B0C0D"
        primary.peripheralIdentifier = UUID()
        let inner = G7InMemoryCredentialStore(primary)
        let guarded = GuardedG7CredentialStore(wrapping: inner)
        let source = makeSource(.primary(slot: .recommendedDefault), store: guarded)
        XCTAssertNotNil(try inner.load(), "the matching record is loaded, not deleted")

        await source.forgetSensor()
        XCTAssertNotNil(try inner.load(), "unasked, G7Kit cannot delete it")
        await guarded.allowingDeletion { await source.forgetSensor() }
        XCTAssertNil(try inner.load())
    }

    // MARK: - m1: Trio is cleared when entering listen mode

    func test_switchingToListenModeRemovesThisAppsReadingsAndHeartbeatKeysFromTrio() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        let store = try XCTUnwrap(persistence.trioStore as? RecordingTrioStore)
        let harness = LiveServicesHarness(persistence, trioEnabled: true)
        await harness.services.bootstrap()
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(120), at: now.addingTimeInterval(-10)))
        XCTAssertEqual(store.payload.count, 1)
        // What this app's heartbeat wrote while pairing (G7Kit's target needs a real sensor).
        store.setString(G7HeartbeatValues.service, forKey: TrioAppGroupContract.heartbeatServiceUUIDKey)
        store.setString(G7HeartbeatValues.characteristic, forKey: TrioAppGroupContract.heartbeatReceiveUUIDKey)
        store.setString(UUID().uuidString, forKey: TrioAppGroupContract.heartbeatDeviceAddressKey)

        try await harness.services.setConnectionMode(.listen)
        XCTAssertTrue(store.payload.isEmpty, "this app's readings are removed from Trio's App Group")
        XCTAssertNil(store.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey), "and its heartbeat keys")
        XCTAssertNil(store.string(forKey: TrioAppGroupContract.heartbeatServiceUUIDKey))
        XCTAssertNil(store.string(forKey: TrioAppGroupContract.heartbeatReceiveUUIDKey))

        let writes = store.writesOfAnyKey
        persistence.clock.advance(by: 5 * 60)
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(118), at: persistence.clock.now.addingTimeInterval(-10)))
        XCTAssertEqual(store.writesOfAnyKey, writes, "and nothing is written after")
    }

    /// With the handoff off (switch off) nothing of this app's is in Trio's App Group: nothing is
    /// touched by the switch either.
    func test_switchingToListenModeWithTheHandoffOffTouchesNothing() async throws {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let store = try XCTUnwrap(persistence.trioStore as? RecordingTrioStore)
        let harness = LiveServicesHarness(persistence, trioEnabled: false)
        await harness.services.bootstrap()
        let writes = store.writesOfAnyKey
        try await harness.services.setConnectionMode(.listen)
        XCTAssertEqual(store.writesOfAnyKey, writes)
    }
}

/// G7 GATT values as xDrip4iOS publishes them for Trio's heartbeat (docs/trio-bridge.md).
private enum G7HeartbeatValues {
    static let service = "F8083532-849E-531C-C594-30F1F86A4EA5"
    static let characteristic = "F8083535-849E-531C-C594-30F1F86A4EA5"
}
