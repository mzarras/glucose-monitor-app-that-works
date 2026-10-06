// Original to Sensor (no ported code).
// Test doubles: repository fake (the GlucoseStore implementation is another workstream's), clock,
// diagnostic log, and reading/session builders.

import Foundation
import GlucoseCore
@testable import NightscoutKit

/// In-memory production-role `GlucoseReadingRepository` following the contract in GlucoseCore
/// GlucoseReadingRepository.swift: whole-batch refusal of `.replay`/`.mock`, of numbers outside
/// 40...400, of non-finite trend rates, and of readings dated after the store clock +
/// `LiveReadingGate.futureTolerance` (D33); insert-or-ignore by id; an `.imported` reading is
/// skipped when any stored reading lies within ±150 s (inclusive); a `.sensor` reading deletes
/// `.imported` readings within ±150 s; a batch is applied in ascending date order.
actor InMemoryGlucoseReadingRepository: GlucoseReadingRepository {
    static let window: TimeInterval = 150
    /// Default store clock for tests: after every fixture date.
    static let defaultNow = Fixtures.date("2026-09-23T00:00:00Z")

    private let clock: any WallClock

    init(clock: any WallClock = TestClock(InMemoryGlucoseReadingRepository.defaultNow)) {
        self.clock = clock
    }

    private(set) var stored: [GlucoseReading] = []
    private(set) var insertCalls = 0
    private var failNextInserts = 0
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    func failNextInsert(times: Int = 1) { failNextInserts = times }

    func insert(_ readings: [GlucoseReading]) async throws -> [GlucoseReading] {
        insertCalls += 1
        if failNextInserts > 0 {
            failNextInserts -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        for reading in readings {
            switch reading.source {
            case .replay, .mock: throw GlucoseReadingRepositoryError.sourceNotAllowed(reading.source)
            case .sensor, .imported: break
            }
            if case .mgdl(let value) = reading.value, !GlucoseValue.sensorReportableRange.contains(value) {
                throw GlucoseReadingRepositoryError.implausibleValue(value)
            }
            if let rate = reading.trendRate, !rate.isFinite {
                throw GlucoseReadingRepositoryError.nonFiniteTrendRate
            }
            if reading.date > clock.now().addingTimeInterval(LiveReadingGate.futureTolerance) {
                throw GlucoseReadingRepositoryError.futureDated(reading.date)
            }
        }
        var added: [GlucoseReading] = []
        var changed = false
        for reading in readings.sorted(by: { $0.date < $1.date }) {
            guard !stored.contains(where: { $0.id == reading.id }) else { continue }
            if case .imported = reading.source {
                if stored.contains(where: { abs($0.date.timeIntervalSince(reading.date)) <= Self.window }) { continue }
            } else if reading.source == .sensor {
                let before = stored.count
                stored.removeAll { existing in
                    if case .imported = existing.source { return abs(existing.date.timeIntervalSince(reading.date)) <= Self.window }
                    return false
                }
                changed = changed || stored.count != before
            }
            stored.append(reading)
            added.append(reading)
        }
        stored.sort { $0.date < $1.date }
        if changed || !added.isEmpty { continuations.values.forEach { $0.yield() } }
        return added
    }

    func readings(from start: Date, to end: Date) async throws -> [GlucoseReading] {
        stored.filter { $0.date >= start && $0.date < end }
    }

    func latestLiveReading() async throws -> GlucoseReading? {
        stored.last { reading in
            if case .imported = reading.source { return false }
            return true
        }
    }

    nonisolated func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let id = UUID()
        Task { await self.addContinuation(continuation, id: id) }
        return stream
    }

    private func addContinuation(_ continuation: AsyncStream<Void>.Continuation, id: UUID) {
        continuations[id] = continuation
    }
}

/// A clock tests move by hand.
final class TestClock: WallClock, @unchecked Sendable {
    // @unchecked Sendable: `current` is only read and written while holding `lock`.
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    func set(_ date: Date) { lock.withLock { current = date } }
}

final class RecordingDiagnosticLog: DiagnosticLog, @unchecked Sendable {
    // @unchecked Sendable: `storage` is only read and written while holding `lock`.
    private let lock = NSLock()
    private var storage: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) { lock.withLock { storage.append(event) } }
    var events: [DiagnosticEvent] { lock.withLock { storage } }
    var messages: [String] { events.map(\.message) }
}

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "fixture \(name)"])
        }
        return url
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// ISO 8601 UTC ("2026-09-19T10:00:00Z", optional fraction) → Date. Independent of the code
    /// under test, for expected values.
    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = iso.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { fatalError("bad test date \(iso)") }
        return date
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightscoutKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A G7-like session and readings inside it.
struct SessionFixture {
    static let serial = "SYNTHG7"
    let start: Date

    init(start: Date = Fixtures.date("2026-09-20T00:00:00Z")) {
        self.start = start
    }

    var session: SensorSession {
        SensorSession(
            serial: Self.serial,
            start: start,
            warmUpEndsAt: start.addingTimeInterval(30 * 60),
            expiresAt: start.addingTimeInterval(10 * 86_400),
            gracePeriodEndsAt: start.addingTimeInterval(10 * 86_400 + 12 * 3_600)
        )
    }

    /// A reading `offset` seconds after session start. `sensorTimestamp` is the offset, as G7 reports it.
    func reading(
        at offset: TimeInterval,
        value: GlucoseValue = .mgdl(120),
        trendRate: Double? = 0.4,
        isBackfill: Bool = false,
        source: ReadingSource = .sensor,
        serial: String = SessionFixture.serial
    ) -> GlucoseReading {
        let date = start.addingTimeInterval(offset)
        let id: String
        if case .imported(let origin) = source {
            id = GlucoseReading.importedID(origin: origin, date: date)
        } else {
            id = GlucoseReading.sensorID(serial: serial, sensorTimestamp: UInt32(max(0, offset)))
        }
        return GlucoseReading(
            id: id, date: date, value: value, trendRate: trendRate,
            isBackfill: isBackfill, source: source, sensorSerial: serial
        )
    }
}
