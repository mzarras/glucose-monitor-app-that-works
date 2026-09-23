// Original to Sensor (no ported code).

import Foundation
import GlucoseCore
import os
@testable import G7Kit

// MARK: - Hex

extension Data {
    /// Test fixtures are written as hex strings; spaces are allowed for readability.
    init(hex: String) {
        let digits = Array(hex.replacingOccurrences(of: " ", with: "").utf8)
        precondition(digits.count % 2 == 0, "odd hex length")
        var bytes: [UInt8] = []
        var index = 0
        while index < digits.count {
            bytes.append(UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16)!)
            index += 2
        }
        self.init(bytes)
    }
}

// MARK: - Clock and log

/// A phone clock the test moves by hand (no sleeping).
final class TestClock: Sendable {
    private let current: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

final class RecordingDiagnosticLog: DiagnosticLog {
    private let events = OSAllocatedUnfairLock<[DiagnosticEvent]>(initialState: [])

    func record(_ event: DiagnosticEvent) {
        events.withLock { $0.append(event) }
    }

    var messages: [String] { events.withLock { $0.map(\.message) } }
}

// MARK: - Fixtures

/// Byte-by-byte builders for sensor messages. The layouts are documented in G7GlucoseMessage,
/// G7BackfillMessage and docs/g7-protocol.md; every field is named here.
enum Fixture {
    /// A `0x4E` response:
    /// [0] 4E, [1] status, [2..5] sensor clock LE, [6..7] sequence LE, [8] 00, [9] 01,
    /// [10..11] age LE, [12..13] glucose LE (FFFF = none), [14] algorithm state, [15] trend,
    /// [16..17] predicted LE (FFFF = none), [18] flags (0x10 = display-only).
    static func glucose(
        status: UInt8 = 0x00,
        sensorClock: UInt32,
        sequence: UInt16 = 1,
        age: UInt16,
        glucose: UInt16?,
        state: UInt8,
        trend: UInt8 = 0x7F,
        predicted: UInt16? = nil,
        flags: UInt8 = 0x0F
    ) -> Data {
        var bytes: [UInt8] = [0x4E, status]
        bytes += G7Bytes.littleEndian(sensorClock)
        bytes += G7Bytes.littleEndian(sequence)
        bytes += [0x00, 0x01]
        bytes += G7Bytes.littleEndian(age)
        bytes += G7Bytes.littleEndian(glucose ?? 0xFFFF)
        bytes += [state, trend]
        bytes += G7Bytes.littleEndian(predicted ?? 0xFFFF)
        bytes += [flags]
        return Data(bytes)
    }

    /// A backfill record: [0..2] timestamp LE (3 bytes), [3] 00, [4..5] glucose LE,
    /// [6] algorithm state, [7] flags (0x10 = display-only), [8] trend.
    static func backfill(timestamp: UInt32, glucose: UInt16?, state: UInt8 = 0x06, flags: UInt8 = 0x0F, trend: UInt8 = 0x7F) -> Data {
        var bytes = Array(G7Bytes.littleEndian(timestamp).prefix(3)) + [0x00]
        bytes += G7Bytes.littleEndian(glucose ?? 0xFFFF)
        bytes += [state, flags, trend]
        return Data(bytes)
    }

    /// Captured 10-day `0x52` (xDrip Tests/DexcomG7CalibrationTests.swift:231-236).
    static let tenDayExtendedVersion = Data(hex: "5200c0d70d00540600020404ff0c00")
    /// Captured 15-day `0x52` (xDrip Tests/DexcomG7CalibrationTests.swift:241-246).
    static let fifteenDayExtendedVersion = Data(hex: "5200406f1400880e00010a04ff1100")
}

// MARK: - Fakes

/// Records what the protocol logic asks of the link. Scheduled work runs only when pumped.
final class FakeLink: G7Link {
    let peripheralIdentifier: UUID
    var peripheralName: String? = "Dexcom4F"
    var notifying: Set<G7Characteristic> = []
    var notifyRequests: [(G7Characteristic, Bool)] = []
    var writes: [(data: Data, characteristic: G7Characteristic, withResponse: Bool)] = []
    var allWrites: [(data: Data, characteristic: G7Characteristic)] = []
    var scheduled: [(delay: TimeInterval, action: () -> Void)] = []
    var disconnectCount = 0
    var acceptWrites = true

    init(identifier: UUID = UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!) {
        peripheralIdentifier = identifier
    }

    func setNotify(_ enabled: Bool, for characteristic: G7Characteristic) {
        notifyRequests.append((characteristic, enabled))
    }

    func isNotifying(_ characteristic: G7Characteristic) -> Bool {
        notifying.contains(characteristic)
    }

    func write(_ data: Data, to characteristic: G7Characteristic, withResponse: Bool) -> Bool {
        guard acceptWrites else { return false }
        writes.append((data, characteristic, withResponse))
        allWrites.append((data, characteristic))
        return true
    }

    func disconnect() {
        disconnectCount += 1
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduled.append((delay, action))
    }
}

final class FakeCentral: G7CentralDriving {
    var scanCount = 0
    var stopScanCount = 0
    var connectRequests: [UUID] = []
    var cancelRequests: [UUID] = []
    /// Identifiers iOS "knows" (retrievePeripherals would find them).
    var known: Set<UUID> = []
    /// Timers the controller asked for; the test fires them with `fireScheduled()`.
    var scheduled: [(delay: TimeInterval, action: () -> Void)] = []

    func scanForSensors() { scanCount += 1 }
    func stopScanning() { stopScanCount += 1 }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) {
        scheduled.append((delay, action))
    }

    func fireScheduled() {
        let jobs = scheduled
        scheduled = []
        jobs.forEach { $0.action() }
    }

    func connect(peripheralIdentifier: UUID) -> Bool {
        connectRequests.append(peripheralIdentifier)
        known.insert(peripheralIdentifier)
        return true
    }

    func cancelConnection(peripheralIdentifier: UUID) {
        cancelRequests.append(peripheralIdentifier)
    }
}

/// Moves bytes between a `FakeLink` and a `G7SensorSimulator`, delivering callbacks in order,
/// as CoreBluetooth would on its queue.
final class LinkDriver {
    let link: FakeLink
    let sensor: G7SensorSimulator
    let deliverNotify: (G7Characteristic, Bool, G7LinkError?) -> Void
    let deliverValue: (G7Characteristic, Data) -> Void
    /// Notify requests for these characteristics fail (simulates a cancelled iOS pairing prompt).
    var failingNotify: [G7Characteristic: G7LinkError] = [:]
    private var pendingValues: [(G7Characteristic, Data)] = []

    init(link: FakeLink, sensor: G7SensorSimulator,
         deliverNotify: @escaping (G7Characteristic, Bool, G7LinkError?) -> Void,
         deliverValue: @escaping (G7Characteristic, Data) -> Void) {
        self.link = link
        self.sensor = sensor
        self.deliverNotify = deliverNotify
        self.deliverValue = deliverValue
    }

    /// Runs until nothing is left to deliver.
    func pump(maxSteps: Int = 100_000) {
        var steps = 0
        while steps < maxSteps {
            steps += 1
            if !link.notifyRequests.isEmpty {
                let (characteristic, enabled) = link.notifyRequests.removeFirst()
                if let error = failingNotify[characteristic] {
                    deliverNotify(characteristic, false, error)
                    continue
                }
                if enabled { link.notifying.insert(characteristic) } else { link.notifying.remove(characteristic) }
                deliverNotify(characteristic, enabled, nil)
                if enabled { pendingValues += sensor.notificationsEnabled(characteristic) }
                continue
            }
            if !link.writes.isEmpty {
                let write = link.writes.removeFirst()
                pendingValues += sensor.handleWrite(write.data, to: write.characteristic)
                continue
            }
            if !pendingValues.isEmpty {
                let (characteristic, value) = pendingValues.removeFirst()
                deliverValue(characteristic, value)
                continue
            }
            if !link.scheduled.isEmpty {
                let index = link.scheduled.indices.min { link.scheduled[$0].delay < link.scheduled[$1].delay }!
                let job = link.scheduled.remove(at: index)
                job.action()
                continue
            }
            return
        }
        preconditionFailure("LinkDriver did not settle")
    }
}

/// Collects up to `count` elements, giving up after `timeout` seconds (a safety net only; every
/// element is already buffered when the tests call this).
func collect<T: Sendable>(_ stream: AsyncStream<T>, count: Int, timeout: TimeInterval = 5) async -> [T] {
    await withTaskGroup(of: [T]?.self) { group in
        group.addTask {
            var collected: [T] = []
            var iterator = stream.makeAsyncIterator()
            while collected.count < count, let element = await iterator.next() {
                collected.append(element)
            }
            return collected
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        var result: [T] = []
        for await value in group {
            if let value {
                result = value
                group.cancelAll()
                break
            }
            group.cancelAll()
        }
        return result
    }
}
