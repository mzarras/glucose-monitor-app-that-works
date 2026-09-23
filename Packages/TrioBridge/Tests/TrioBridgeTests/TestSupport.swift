// Test doubles and fixtures shared by the TrioBridge tests. Hand-computed values; no network, no sleeping.

import Foundation
import GlucoseCore
@testable import TrioBridge

/// Fixed sensor session. The start has a fractional second (.123) so every derived reading date does
/// too, which proves the bridge writes milliseconds rather than rounding to the second (S3).
enum Fixture {
    static let serial = "3MTEST0001"
    /// 2025-09-16T05:20:00.123Z
    static let sessionStart = Date(timeIntervalSince1970: 1_758_000_000.123)

    static let session = SensorSession(
        serial: serial,
        start: sessionStart,
        warmUpEndsAt: sessionStart.addingTimeInterval(30 * 60),
        expiresAt: sessionStart.addingTimeInterval(10 * 86_400),
        gracePeriodEndsAt: sessionStart.addingTimeInterval(10 * 86_400 + 12 * 3_600)
    )

    /// A reading `sensorSeconds` after session start. Its id is built the way G7Kit builds it
    /// (serial + sensor timestamp), so a backfilled copy of the same sensor time has the same id.
    static func reading(
        at sensorSeconds: UInt32,
        value: GlucoseValue = .mgdl(120),
        rate: Double? = 0.2,
        backfill: Bool = false,
        source: ReadingSource = .sensor,
        serial: String = serial,
        sessionStart: Date = sessionStart
    ) -> GlucoseReading {
        GlucoseReading(
            id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: sensorSeconds),
            date: sessionStart.addingTimeInterval(TimeInterval(sensorSeconds)),
            value: value,
            trendRate: rate,
            isBackfill: backfill,
            source: source,
            sensorSerial: serial
        )
    }

    /// Readings every 5 minutes from `firstSeconds`, oldest first.
    static func series(from firstSeconds: UInt32, count: Int) -> [GlucoseReading] {
        (0..<count).map { reading(at: firstSeconds + UInt32($0) * 300, value: .mgdl(100 + $0 % 50)) }
    }

    /// The date of `sensorSeconds` after session start — used as "now" just after a reading arrives.
    static func time(_ sensorSeconds: UInt32) -> Date {
        sessionStart.addingTimeInterval(TimeInterval(sensorSeconds))
    }
}

/// A clock tests can move. `@unchecked Sendable`: its only mutable state is guarded by `lock`.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}

/// In-memory stand-in for Trio's App Group suite, with failure injection and an operation log.
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class InMemoryTrioStore: TrioSharedStore, @unchecked Sendable {
    private let lock = NSLock()
    private var dataValues: [String: Data] = [:]
    private var stringValues: [String: String] = [:]
    private var _operations: [String] = []
    private var _accessError: TrioBridgeError?
    private var _dropsDataWrites = false

    /// When set, `checkAccess()` throws it (e.g. missing entitlement).
    var accessError: TrioBridgeError? {
        get { lock.lock(); defer { lock.unlock() }; return _accessError }
        set { lock.lock(); defer { lock.unlock() }; _accessError = newValue }
    }

    /// When true, `setData` silently does nothing, so the read-back check fails.
    var dropsDataWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _dropsDataWrites }
        set { lock.lock(); defer { lock.unlock() }; _dropsDataWrites = newValue }
    }

    /// Every mutating call, in order, e.g. "setString cgmTransmitterDeviceAddress".
    var operations: [String] {
        lock.lock(); defer { lock.unlock() }
        return _operations
    }

    /// Number of `setData` calls for the readings key.
    var readingWrites: Int {
        operations.filter { $0 == "setData \(TrioAppGroupContract.readingsKey)" }.count
    }

    var payload: Data? { data(forKey: TrioAppGroupContract.readingsKey) }

    func checkAccess() throws(TrioBridgeError) {
        if let error = accessError { throw error }
    }

    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return dataValues[key]
    }

    func setData(_ data: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        _operations.append("setData \(key)")
        if !_dropsDataWrites { dataValues[key] = data }
    }

    func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return stringValues[key]
    }

    func setString(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        _operations.append("setString \(key)")
        stringValues[key] = value
    }

    func removeValue(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        _operations.append("remove \(key)")
        dataValues[key] = nil
        stringValues[key] = nil
    }
}

/// Collects diagnostic events. `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class RecordingDiagnosticLog: DiagnosticLog, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [DiagnosticEvent] = []

    var events: [DiagnosticEvent] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    func record(_ event: DiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        _events.append(event)
    }
}
