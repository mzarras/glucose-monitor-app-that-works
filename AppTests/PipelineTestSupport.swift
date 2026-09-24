// Fakes and helpers for the pipeline, services and replay tests (Integrator A). Nothing here
// talks to Bluetooth, the network, Trio's real App Group or the notification center.
//
// Name clashes to keep in mind: the app target declares its own `AlertKind`, `QuietHours`,
// `AlertDeliveryStatus` and `UploadStatus`, which are ambiguous with AlertEngine's / NightscoutKit's
// in a file importing both. These helpers therefore identify alerts by the `alertKind` string in
// a notification's userInfo ("urgentLow", "missedReadings", …).

import AlertEngine
import Foundation
import GlucoseCore
import NightscoutKit
import TrioBridge
import XCTest
@testable import Sensor

/// A settable clock for the pipeline, the store, the alert service, the Trio bridge and uploaders.
final class PipelineTestClock: @unchecked Sendable {
    // @unchecked Sendable: `current` is only read and written while holding `lock`.
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func set(_ date: Date) {
        lock.withLock { current = date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }

    var closure: @Sendable () -> Date { { self.now } }
}

struct PipelineTestWallClock: WallClock {
    let clock: PipelineTestClock
    func now() -> Date { clock.now }
}

/// Records what the alert service hands to UNUserNotificationCenter.
@MainActor
final class RecordingNotificationCenter: AlertNotificationCenter {
    struct Posted {
        let spec: NotificationRequestSpec
        let at: Date
        var kind: String { spec.userInfo[AlertNotificationIDs.userInfoKind] ?? "?" }
    }

    var permissions = NotificationPermissionState(
        authorization: .authorized, alerts: .enabled, sounds: .enabled, criticalAlerts: .notSupported, timeSensitive: .enabled
    )
    private(set) var posted: [Posted] = []
    private(set) var pending: [String: NotificationRequestSpec] = [:]
    private let clock: PipelineTestClock

    init(clock: PipelineTestClock) {
        self.clock = clock
    }

    func registerCategories() async {}
    func requestAuthorization() async -> NotificationPermissionState { permissions }
    func permissionState() async -> NotificationPermissionState { permissions }

    func add(_ request: NotificationRequestSpec) async throws {
        if request.fireDate == nil {
            posted.append(Posted(spec: request, at: clock.now))
        } else {
            pending[request.identifier] = request
        }
    }

    func removePending(identifiers: [String]) {
        for id in identifiers { pending[id] = nil }
    }

    func removeDelivered(identifiers: [String]) {}

    func posted(_ kind: String) -> [Posted] {
        posted.filter { $0.kind == kind }
    }

    /// Pending notifications for `kind`, earliest first.
    func pending(_ kind: String) -> [NotificationRequestSpec] {
        pending.values.filter { $0.userInfo[AlertNotificationIDs.userInfoKind] == kind }
            .sorted { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }
    }
}

/// Records the in-app (ringer-off) sounds.
@MainActor
final class RecordingAudioPlayer: AlertAudioPlaying {
    private(set) var plays: [(fileName: String, at: Date)] = []
    private(set) var isPlaying = false
    var outputVolume: Float? = 0.8
    private let clock: PipelineTestClock

    init(clock: PipelineTestClock) {
        self.clock = clock
    }

    func play(fileName: String, loopSeconds: TimeInterval) -> Bool {
        plays.append((fileName, clock.now))
        isPlaying = false // finishes at once: every repeat can play again
        return true
    }

    func stop() {
        isPlaying = false
    }
}

/// Trio's App Group suite, in memory. Counts every write and removal of `latestReadings`.
final class RecordingTrioStore: TrioSharedStore, @unchecked Sendable {
    // @unchecked Sendable: every access to the dictionaries and counters holds `lock`.
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    private var strings: [String: String] = [:]
    private var readingWrites = 0

    func checkAccess() throws(TrioBridgeError) {}

    func data(forKey key: String) -> Data? { lock.withLock { data[key] } }

    func setData(_ value: Data, forKey key: String) {
        lock.withLock {
            data[key] = value
            if key == TrioAppGroupContract.readingsKey { readingWrites += 1 }
        }
    }

    func string(forKey key: String) -> String? { lock.withLock { strings[key] } }
    func setString(_ value: String, forKey key: String) { lock.withLock { strings[key] = value } }

    func removeValue(forKey key: String) {
        lock.withLock {
            data[key] = nil
            strings[key] = nil
        }
    }

    var writesOfReadings: Int { lock.withLock { readingWrites } }

    /// The `latestReadings` payload as JSON objects, newest first.
    var payload: [[String: Any]] {
        guard let raw = data(forKey: TrioAppGroupContract.readingsKey),
              let array = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else { return [] }
        return array
    }
}

/// An upload destination that records every batch instead of sending it.
final class RecordingUploadDestination: UploadDestination, @unchecked Sendable {
    // @unchecked Sendable: `batches` is only read and written while holding `lock`.
    private let lock = NSLock()
    private var batches: [[GlucoseReading]] = []
    let name = "Recording"
    let maxBatchSize = 100
    let maxReadingAge: TimeInterval? = nil

    func canRepresent(_ value: GlucoseValue) -> Bool { true }

    func upload(_ readings: [GlucoseReading]) async throws(UploadError) {
        lock.withLock { batches.append(readings) }
    }

    var uploaded: [GlucoseReading] { lock.withLock { batches.flatMap { $0 } } }
}

/// A CGM source a test drives by hand.
final class ScriptedCGMSource: CGMSource, @unchecked Sendable {
    // @unchecked Sendable: `session` is only read and written while holding `lock`; the
    // continuations are Sendable.
    let readings: AsyncStream<GlucoseReading>
    let state: AsyncStream<SensorState>
    private let readingsContinuation: AsyncStream<GlucoseReading>.Continuation
    private let stateContinuation: AsyncStream<SensorState>.Continuation
    private let lock = NSLock()
    private var session: SensorSession?

    init(session: SensorSession?) {
        (readings, readingsContinuation) = AsyncStream.makeStream(of: GlucoseReading.self, bufferingPolicy: .unbounded)
        (state, stateContinuation) = AsyncStream.makeStream(of: SensorState.self, bufferingPolicy: .unbounded)
        self.session = session
    }

    var currentSession: SensorSession? {
        get async { lock.withLock { session } }
    }

    func setSession(_ newSession: SensorSession?) {
        lock.withLock { session = newSession }
    }

    func start(pairingCode: String?) async throws {}
    func stop() async {}

    func deliver(_ reading: GlucoseReading) {
        readingsContinuation.yield(reading)
    }

    func deliver(state newState: SensorState) {
        stateContinuation.yield(newState)
    }
}

/// Collects diagnostic events.
final class CollectingDiagnosticLog: DiagnosticLog, @unchecked Sendable {
    // @unchecked Sendable: `events` is only read and written while holding `lock`.
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        lock.withLock { events.append(event) }
    }

    var messages: [String] { lock.withLock { events.map(\.message) } }
}

enum PipelineFixtures {
    /// 2030-01-01T00:00:00Z (hand-computed: 1_893_456_000 s since 1970).
    static let start = Date(timeIntervalSince1970: 1_893_456_000)
    static let serial = "TESTG7-1A2B3C4D"

    /// Two days old at `start`: warm-up long over.
    static let session = SensorSession(
        serial: serial,
        start: start.addingTimeInterval(-2 * 86_400),
        warmUpEndsAt: start.addingTimeInterval(-2 * 86_400 + 27 * 60),
        expiresAt: start.addingTimeInterval(8 * 86_400),
        gracePeriodEndsAt: start.addingTimeInterval(8 * 86_400 + 12 * 3_600)
    )

    static func reading(_ value: GlucoseValue, at date: Date, rate: Double? = 0, backfill: Bool = false, serial: String = serial) -> GlucoseReading {
        let sensorTimestamp = UInt32(max(0, date.timeIntervalSince(session.start)))
        return GlucoseReading(
            id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: sensorTimestamp),
            date: date, value: value, trendRate: rate, isBackfill: backfill, source: .sensor, sensorSerial: serial
        )
    }

    static func imported(_ value: GlucoseValue, at date: Date) -> GlucoseReading {
        GlucoseReading(
            id: GlucoseReading.importedID(origin: .nightscout, date: date), date: date, value: value, trendRate: nil,
            isBackfill: false, source: .imported(.nightscout), sensorSerial: ""
        )
    }

    static var utcConfiguration: AlertEngineConfiguration {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return AlertEngineConfiguration(calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p2a-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Waits (real time, polling) until `condition` holds; fails the test after `timeout`.
@MainActor
func waitUntil(_ description: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
               _ condition: @MainActor () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        if Date() > deadline {
            XCTFail("timed out waiting for: \(description)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}
