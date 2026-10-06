// The services around the pipeline: the D20 DEBUG switch for Trio and uploads, the Trio heartbeat
// keys, uploader replacement (one per queue file), force-quit gap detection, the diagnostic log.

import AlertEngine
import Foundation
import G7Kit
import GlucoseStore
import GlucoseCore
import NightscoutKit
import TrioBridge
import XCTest
@testable import Sensor

@MainActor
final class ServicesCoordinatorTests: XCTestCase {
    private let trioGroup = "group.org.nightscout.ABCDE12345.trio.trio-app-group"

    // MARK: - D20: Trio and uploads off in a DEBUG build unless the developer switch is on

    func test_S6_trioBridgeIsNotAttachedWithoutLiveOutputsAllowed() {
        let trio = TrioCoordinator(appGroupID: trioGroup, store: RecordingTrioStore(), diagnostics: NullDiagnosticLog())
        trio.configure(enabled: true, liveOutputsAllowed: false)
        XCTAssertNil(trio.activeBridge, "D20: the bridge must stay off in DEBUG without the developer switch")
        trio.configure(enabled: false, liveOutputsAllowed: true)
        XCTAssertNil(trio.activeBridge, "off when the user turned it off")
        trio.configure(enabled: true, liveOutputsAllowed: true)
        XCTAssertNotNil(trio.activeBridge)
    }

    func test_S6_uploadersAreNotCreatedWithoutLiveOutputsAllowed() async throws {
        let uploads = UploadCoordinator(
            credentials: InMemoryCredentialStore([.nightscoutToken: "t", .dexcomShareAccountName: "a", .dexcomSharePassword: "p"]),
            queueDirectory: PipelineFixtures.temporaryDirectory(), deviceName: "Sensor", transport: NeverCalledTransport(),
            diagnostics: NullDiagnosticLog()
        )
        var configuration = UploadCoordinator.Configuration(
            nightscoutEnabled: true, nightscoutSite: try NightscoutSite("https://example.invalid"), nightscoutHasToken: true,
            shareEnabled: true, shareRegion: .us, shareReceiverSerial: "SM12345678", shareHasCredentials: true,
            liveOutputsAllowed: false
        )
        await uploads.apply(configuration)
        XCTAssertTrue(uploads.activeUploaders.isEmpty, "D20: no uploader in DEBUG without the developer switch")
        configuration.liveOutputsAllowed = true
        await uploads.apply(configuration)
        XCTAssertEqual(uploads.activeUploaders.count, 2)
        configuration.liveOutputsAllowed = false
        await uploads.apply(configuration)
        XCTAssertTrue(uploads.activeUploaders.isEmpty)
    }

    /// NightscoutKit allows one uploader per queue file: changing the site releases the old uploader
    /// (and its status task) before the new one is created, so no `QueueFileInUse` appears.
    func test_S5_replacingAnUploaderReleasesTheQueueFileFirst() async throws {
        let uploads = UploadCoordinator(
            credentials: InMemoryCredentialStore([.nightscoutToken: "t"]), queueDirectory: PipelineFixtures.temporaryDirectory(),
            deviceName: "Sensor", transport: NeverCalledTransport(), diagnostics: NullDiagnosticLog()
        )
        var configuration = UploadCoordinator.Configuration(
            nightscoutEnabled: true, nightscoutSite: try NightscoutSite("https://one.example.invalid"), nightscoutHasToken: true,
            shareEnabled: false, shareRegion: .us, shareReceiverSerial: nil, shareHasCredentials: false, liveOutputsAllowed: true
        )
        await uploads.apply(configuration)
        XCTAssertEqual(uploads.activeUploaders.count, 1)
        configuration.nightscoutSite = try NightscoutSite("https://two.example.invalid")
        await uploads.apply(configuration)
        XCTAssertEqual(uploads.activeUploaders.count, 1)
        XCTAssertNil(uploads.nightscoutSummary.setupError, "the old uploader must be released before the new one claims the file")
    }

    /// Phase 2 review M2: an uploader replaced while the old one is still alive (a flush in
    /// progress holds it, so its queue file is in use) is surfaced as failing, retried, and — the
    /// point — the pipeline then uploads through the new uploader without being re-attached.
    func test_S5_pipelineUploadsThroughAReplacedUploader() async throws {
        let transport = RecordingTransport()
        let uploads = UploadCoordinator(
            credentials: InMemoryCredentialStore([.nightscoutToken: "t"]), queueDirectory: PipelineFixtures.temporaryDirectory(),
            deviceName: "Sensor", transport: transport, diagnostics: NullDiagnosticLog(), setupRetryDelay: .milliseconds(50)
        )
        var configuration = UploadCoordinator.Configuration(
            nightscoutEnabled: true, nightscoutSite: try NightscoutSite("https://one.example.invalid"), nightscoutHasToken: true,
            shareEnabled: false, shareRegion: .us, shareReceiverSerial: nil, shareHasCredentials: false, liveOutputsAllowed: true
        )
        await uploads.apply(configuration)

        // The pipeline, wired as LiveAppServices.attachOutputs does. Readings dated now (the
        // uploader's own gate uses the real clock).
        let now = Date()
        let session = SensorSession(
            serial: PipelineFixtures.serial, start: now.addingTimeInterval(-2 * 86_400), warmUpEndsAt: now.addingTimeInterval(-2 * 86_400 + 27 * 60),
            expiresAt: now.addingTimeInterval(8 * 86_400), gracePeriodEndsAt: now.addingTimeInterval(8 * 86_400 + 12 * 3_600)
        )
        let source = ScriptedCGMSource(session: session)
        let pipeline = ReadingPipeline(name: "uploads", source: source, diagnostics: NullDiagnosticLog(), now: { Date() })
        defer { pipeline.stopConsuming() }
        pipeline.outputs.uploaders = { uploads.activeUploaders }
        pipeline.outputs.flushUploads = { uploads.flushIfDue() }
        pipeline.startConsuming()
        pipeline.attach(store: try GlucoseStore.productionInMemory())
        pipeline.activate()

        // A flush in progress keeps the old uploader (and its queue file) alive during the change.
        var inFlight: ReadingUploader? = uploads.activeUploaders.first
        XCTAssertNotNil(inFlight)
        configuration.nightscoutSite = try NightscoutSite("https://two.example.invalid")
        await uploads.apply(configuration)
        XCTAssertTrue(uploads.activeUploaders.isEmpty)
        XCTAssertNotNil(uploads.nightscoutSummary.setupError)
        XCTAssertTrue(uploads.nightscoutSummary.isFailing, "QueueFileInUse must be surfaced (S5)")

        // The flush ends; the retry creates the new uploader.
        inFlight = nil
        await waitUntil("replacement uploader created") { uploads.activeUploaders.count == 1 }
        XCTAssertNil(uploads.nightscoutSummary.setupError)

        let reading = GlucoseReading(
            id: GlucoseReading.sensorID(serial: PipelineFixtures.serial, sensorTimestamp: UInt32(2 * 86_400 - 60)),
            date: now.addingTimeInterval(-60), value: .mgdl(123), trendRate: 0.4, isBackfill: false, source: .sensor,
            sensorSerial: PipelineFixtures.serial
        )
        source.deliver(reading)
        await waitUntil("uploaded through the new uploader") { !transport.requests.isEmpty }
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.host, "two.example.invalid")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"date\":\(GlucoseReading.epochMilliseconds(reading.date))"), body)
    }

    // MARK: - Trio bridge turned on in a build that cannot reach Trio (review minor 4)

    func test_S5_trioBridgeOnWithoutAnAppGroupIsFailing() {
        let trio = TrioCoordinator(appGroupID: nil, store: nil, diagnostics: NullDiagnosticLog())
        trio.configure(enabled: true, liveOutputsAllowed: true)
        XCTAssertNil(trio.activeBridge)
        XCTAssertNotNil(trio.summary.unavailableReason)
        XCTAssertTrue(trio.summary.isFailing)
        guard case .writeFailing = trio.summary.alertInput else {
            return XCTFail("the Trio bridge alert must fire when the bridge is on but cannot run: \(trio.summary.alertInput)")
        }
        trio.configure(enabled: false, liveOutputsAllowed: true)
        XCTAssertNil(trio.summary.unavailableReason)
        XCTAssertFalse(trio.summary.isFailing)
        guard case .off = trio.summary.alertInput else { return XCTFail("off when turned off") }
    }

    // MARK: - Trio heartbeat (docs/trio-bridge.md "Heartbeat wiring")

    func test_heartbeatIsPublishedOnlyWithAPairingAndTheBridgeOn() async {
        let store = RecordingTrioStore()
        let trio = TrioCoordinator(appGroupID: trioGroup, store: store, diagnostics: NullDiagnosticLog())
        let peripheral = TrioHeartbeatPeripheral(
            peripheralIdentifier: UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!,
            serviceUUID: "F8083532-849E-531C-C594-30F1F86A4EA5", receiveCharacteristicUUID: "F8083535-849E-531C-C594-30F1F86A4EA5"
        )
        // Bridge off: the App Group is not touched, even to remove stale keys.
        store.setString("STALE-XDRIP", forKey: TrioAppGroupContract.heartbeatDeviceAddressKey)
        await trio.updateHeartbeat(peripheral)
        XCTAssertEqual(store.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey), "STALE-XDRIP")

        // Bridge on, no pairing: stale keys are removed.
        trio.configure(enabled: true, liveOutputsAllowed: true)
        await trio.updateHeartbeat(nil)
        XCTAssertNil(store.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey))
        XCTAssertFalse(trio.summary.heartbeatPublished)

        // Pairing: published, service and characteristic first (checked by TrioBridge).
        await trio.updateHeartbeat(peripheral)
        XCTAssertEqual(store.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey), peripheral.peripheralIdentifier.uuidString)
        XCTAssertEqual(store.string(forKey: TrioAppGroupContract.heartbeatServiceUUIDKey), peripheral.serviceUUID)
        XCTAssertEqual(store.string(forKey: TrioAppGroupContract.heartbeatReceiveUUIDKey), peripheral.receiveCharacteristicUUID)
        XCTAssertTrue(trio.summary.heartbeatPublished)

        // Bridge turned off: readings and keys removed.
        await trio.removeEverythingFromTrio()
        XCTAssertNil(store.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey))
        XCTAssertNil(store.string(forKey: TrioAppGroupContract.heartbeatServiceUUIDKey))
        XCTAssertFalse(trio.summary.heartbeatPublished)
    }

    /// Review minor 8: another app (an old xDrip4iOS) writes its heartbeat keys after ours; the next
    /// re-evaluation puts ours back (or removes them when there is no pairing), instead of trusting
    /// what this process wrote last.
    func test_heartbeatKeysWrittenLaterByAnotherAppAreReplaced() async {
        let store = RecordingTrioStore()
        let trio = TrioCoordinator(appGroupID: trioGroup, store: store, diagnostics: NullDiagnosticLog())
        trio.configure(enabled: true, liveOutputsAllowed: true)
        let ours = TrioHeartbeatPeripheral(
            peripheralIdentifier: UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!,
            serviceUUID: "F8083532-849E-531C-C594-30F1F86A4EA5", receiveCharacteristicUUID: "F8083535-849E-531C-C594-30F1F86A4EA5"
        )
        await trio.updateHeartbeat(ours)
        store.setString("XDRIP-OLD-TRANSMITTER", forKey: TrioAppGroupContract.heartbeatDeviceAddressKey)
        await trio.updateHeartbeat(ours)
        XCTAssertEqual(store.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey), ours.peripheralIdentifier.uuidString)

        await trio.updateHeartbeat(nil)
        store.setString("XDRIP-OLD-TRANSMITTER", forKey: TrioAppGroupContract.heartbeatDeviceAddressKey)
        await trio.updateHeartbeat(nil)
        XCTAssertNil(store.string(forKey: TrioAppGroupContract.heartbeatDeviceAddressKey))
    }

    // MARK: - Force-quit gap (HANDOFF §4.6)

    func test_S5_forceQuitGapIsReportedOnlyForASilenceWithAnActiveSensor() {
        let t = PipelineFixtures.start
        let beat = PipelineHeartbeat(at: t, sensorWasActive: true, boot: "boot-1")
        let later = t.addingTimeInterval(40 * 60)
        XCTAssertEqual(
            ForceQuitGapDetector.gap(lastHeartbeat: beat, launchedByBluetoothRestoration: false, now: later, boot: "boot-1"),
            ForceQuitGapReport(from: t, to: later)
        )
        XCTAssertNil(ForceQuitGapDetector.gap(lastHeartbeat: beat, launchedByBluetoothRestoration: true, now: later, boot: "boot-1"),
                     "iOS relaunched the app for Bluetooth: it was not force-quit")
        XCTAssertNil(ForceQuitGapDetector.gap(lastHeartbeat: beat, launchedByBluetoothRestoration: false, now: t.addingTimeInterval(14 * 60), boot: "boot-1"),
                     "under 15 minutes is a normal gap between wakes")
        XCTAssertNil(ForceQuitGapDetector.gap(lastHeartbeat: beat, launchedByBluetoothRestoration: false, now: later, boot: "boot-2"),
                     "a restart is not a force-quit")
        let idle = PipelineHeartbeat(at: t, sensorWasActive: false, boot: "boot-1")
        XCTAssertNil(ForceQuitGapDetector.gap(lastHeartbeat: idle, launchedByBluetoothRestoration: false, now: later, boot: "boot-1"),
                     "no sensor delivering: nothing was missed")
        XCTAssertTrue(ForceQuitGapDetector.sensorIsActive(.gracePeriod(endsAt: t)))
        XCTAssertFalse(ForceQuitGapDetector.sensorIsActive(.warmingUp(endsAt: t)))
    }

    // MARK: - Diagnostics

    func test_diagnosticLogKeepsTheNewestEventsAndSavesThemAcrossLaunches() throws {
        let file = PipelineFixtures.temporaryDirectory().appendingPathComponent("diagnostics.json")
        let first = RingBufferDiagnosticLog(capacity: 10, fileURL: file)
        first.loadSaved()
        for index in 0..<25 {
            first.record(DiagnosticEvent(date: PipelineFixtures.start.addingTimeInterval(TimeInterval(index)), category: .ble, message: "event \(index)"))
        }
        XCTAssertEqual(first.snapshot.map(\.message), (15..<25).map { "event \($0)" })
        try first.save()

        let second = RingBufferDiagnosticLog(capacity: 10, fileURL: file)
        second.record(DiagnosticEvent(date: PipelineFixtures.start, category: .app, message: "new launch"))
        second.loadSaved()
        XCTAssertEqual(second.snapshot.last?.message, "new launch")
        XCTAssertEqual(second.snapshot.first?.message, "event 16")
        XCTAssertTrue(second.exportText().contains("[ble] event 24"))
    }
}

/// A transport that fails the test if anything tries to reach the network.
struct NeverCalledTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws(TransportError) -> HTTPResponse {
        XCTFail("unexpected network request to \(request.url?.absoluteString ?? "?")")
        throw TransportError(message: "tests never use the network")
    }
}
