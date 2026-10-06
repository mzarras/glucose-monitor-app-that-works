// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the primary-mode connection policy of CGMG7Transmitter (connect :429-444, didDiscover
// :553-593, reconnectAfterDisconnect :595-603, didConnect :605-654, didDisconnectPeripheral
// :656-688, authSessionDidRejectPersistedKey :969-979, authSessionRequiresCleanReconnect
// :981-989) and BluetoothTransmitter's pending-connect reconnect (BluetoothTransmitter.swift:313-317),
// with pairing state in G7CredentialStore instead of Core Data/UserDefaults. Listen mode (D45): the
// coexistence attach policy of CGMG7Transmitter (connect :429-444, didDiscover :553-571,
// startCoexistenceObservation :2082-2087, handleCoexistenceAuthentication :1587-1609) without any
// command it sends in coexistence (see G7ListenCycle).

import Foundation
import GlucoseCore

/// Why `start(pairingCode:)` refused.
public enum G7StartError: Error, Equatable, Sendable {
    /// The code must be exactly four ASCII digits (CGMG7Transmitter.swift:357, :504).
    case invalidPairingCode
    /// The credential store failed; nothing was started. The state stream reports
    /// `.failed(credentialsUnavailable)`; call `start` again later (e.g. after the first unlock).
    case credentialStoreFailed(String)
    /// `pairAgain(code:)` needs a sensor this phone has connected to before; use `pair(code:)`.
    case noSensorToPairAgain
    /// Pairing (`pair(code:)`, `pairAgain(code:)`) does not exist in listen mode (D45): the Dexcom app
    /// owns the sensor. Switch to primary mode first (`G7CGMSource.setMode`).
    case notAvailableInListenMode
}

/// Everything G7Kit decides across connections: pairing, reconnection, the reading pipeline, the
/// persisted session, calibration and state, in primary mode, and in listen mode (D45, "Listen
/// mode" below) the observation of the Dexcom app's connection. Not thread-safe: `G7CGMSource`
/// calls every method on its one serial queue (the CoreBluetooth delegate queue).
final class G7Controller: G7ConnectionCycleDelegate, G7ListenCycleDelegate {
    struct Output {
        let reading: (GlucoseReading) -> Void
        let state: (SensorState) -> Void
        let calibration: (CalibrationUpdate) -> Void
    }

    /// Sensor policy (safety review): a found sensor that has not connected within 60 s is given up
    /// and scanning resumes. xDrip4iOS uses the same mechanism with 5 s (BluetoothTransmitter.swift:212,
    /// :643-654); a longer wait suits a sensor that advertises only every few minutes.
    static let candidateConnectTimeout: TimeInterval = 60

    /// Sensor policy (safety review follow-up): after this many consecutive failed saves of the
    /// pairing record, `.failed(credentialsUnavailable)` is emitted on every further failed save. One
    /// failure can be transient (the Keychain briefly unavailable); a record is saved at least once
    /// per sensor wake, so three means the problem has lasted about one to three wakes.
    static let saveFailuresBeforeSurfacing = 3

    /// Sensor policy (re-review N1): during a new pairing, the previous sensor's refusal of the new
    /// code is skipped silently only this long after the pairing started. The G7 wakes about every
    /// 5 minutes, so 10 minutes gives the new sensor two chances to advertise. If by then no sensor
    /// has authenticated, the skipped refusal is reported (`previousSensorRejectedCode`).
    static let previousSensorSkipLimit: TimeInterval = 10 * 60

    /// Sensor policy (listen mode): an observed connection that ends without an observed
    /// authenticated status can be a subscription that came too late; only this many in a row are
    /// surfaced (`listenNoAuthenticatedConnection`). Signal loss is covered by missed readings.
    static let listenUnauthenticatedConnectionsBeforeSurfacing = 2
    /// Sensor policy (listen mode): while no sensor is followed yet, look for the Dexcom app's
    /// connection this often (foreground; CoreBluetooth coalesces repeated discoveries).
    static let listenSearchInterval: TimeInterval = 10
    /// D49: the session length is first awaited from observed `52` answers; this app asks itself only
    /// from this wake with proof on.
    static let listenWakesBeforeSessionLengthQuery = 2
    /// Sensor policy (review m6, N1): after a listen connection to the followed sensor failed before a
    /// cycle could start (service discovery failed, connect failed) *while the Dexcom app still holds
    /// the link*, the next attempt waits this long, doubling up to `listenRetryMaximumDelay`, so a
    /// failing attach cannot loop on that link. When the link is down, a pending connection is armed
    /// at once instead (it completes only at the sensor's next advertisement, so it cannot loop).
    static let listenRetryInitialDelay: TimeInterval = 30
    static let listenRetryMaximumDelay: TimeInterval = 5 * 60

    private let store: G7CredentialStore
    private let diagnostics: DiagnosticLog
    private let now: () -> Date
    /// Primary or listen (D45); changed only by `setMode`, never automatically.
    private(set) var mode: G7ConnectionMode
    /// D47: log every received glucose packet's hex.
    var recordsRawGlucosePackets: Bool
    private var slot: G7AuthenticationSlot {
        if case .primary(let slot) = mode { return slot }
        return .recommendedDefault
    }
    private var isListening: Bool { mode == .listen }
    private let output: Output
    private let makeAuthSession: (G7Link, G7PairingRecord) -> G7AuthSession
    weak var central: G7CentralDriving?

    private var record: G7PairingRecord?
    private var pipeline: G7ReadingPipeline?
    private let calibration: G7CalibrationQueue
    private var cycle: G7ConnectionCycle?
    private var isRunning = false
    private var bluetoothPower: G7BluetoothPower = .unknown
    /// Latest state the sensor itself reported (warm-up/active/…); Bluetooth and failure states excluded.
    private(set) var lastSensorState: SensorState?
    private var lastEmittedState: SensorState?
    /// During a new pairing: the CoreBluetooth identifiers of the previous sensor (when finished) and
    /// of every sensor that rejected the code or did not connect. Identifiers, not names: G7 names are
    /// "DXCM" + 2 characters and repeat across sensors (re-review N1).
    private var excludedIdentifiers: Set<UUID> = []
    /// During a new pairing: the stored sensor it replaces, by its CoreBluetooth identifier. Its
    /// refusal of the new code is expected and is skipped silently within `previousSensorSkipLimit`
    /// (coordinator decision after D37; re-review N1).
    private var previousSensor: (name: String, identifier: UUID)?
    private var pairingStartedAt: Date?
    private var skippedPreviousSensorRefusal = false
    /// Bumped by every new pairing, pair-again and forget, so a timer from an earlier one does nothing.
    private var pairingGeneration = 0
    /// The advertised sensor being connected to: a new-pairing candidate, or the paired sensor found
    /// again under a new iOS identifier.
    private var candidate: (name: String, identifier: UUID)?
    private var candidateAttempt = 0
    /// Consecutive connections that authenticated with our own solicited status and then saw a `05`
    /// rejection (safety review P9): from the second one on, another app is the likely cause.
    private var rejectionAfterAuthenticationStreak = 0
    private var connectionAuthenticated = false
    private var connectionRejectedAfterAuthentication = false
    private var consecutiveSaveFailures = 0
    /// The last failure the reading pipeline surfaced, until a later sensor report clears it. While
    /// it is a clock mismatch the phone ↔ sensor time relation is not trusted, so a fingerstick
    /// cannot be converted to sensor time and calibration is refused (D37).
    private var lastPipelineFailure: SensorFailure.Kind?
    /// Audit m1: what the app has durably stored, per sensor serial (only the latest call is kept).
    private var backfillFloor: (serial: String, floor: G7ReadingPipeline.BackfillFloor)?
    /// Listen mode: the observed connection, the system-connected sensor being attached while no
    /// sensor is followed yet, and connections that ended without an observed authentication.
    private var listenCycle: G7ListenCycle?
    private var listenCandidate: G7ConnectedSensor?
    private var listenConnectionsWithoutAuthentication = 0
    private var listenSearchScheduled = false
    /// D49: connections of the followed sensor with proof of an authenticated link; from the second
    /// one on, one `52` query per connection is allowed while the session length is unknown.
    private var listenWakesWithProof = 0
    /// Review m4: peripherals this app saw advertising as a G7 ("DXCM" + 2 characters). A connected G7
    /// may report "Dexcom" + 2 characters, which a G6 also uses; that name is accepted only for a
    /// peripheral seen advertising as a G7.
    private var advertisedG7Names: [UUID: String] = [:]
    /// Review m6: the current retry backoff (0 = none) and whether this connection got a cycle.
    private var listenRetryDelay: TimeInterval = 0
    private var listenRetryGeneration = 0
    private var listenRetryPending = false
    private var listenConnectionHadCycle = false
    /// Review N1b: a connect request to the followed sensor is outstanding (pending, or attaching to
    /// the Dexcom app's link); a further discovery in the same wake does not attach again.
    private var listenAttachInFlight = false

    init(
        store: G7CredentialStore,
        diagnostics: DiagnosticLog,
        now: @escaping () -> Date,
        slot: G7AuthenticationSlot = .recommendedDefault,
        mode: G7ConnectionMode? = nil,
        recordsRawGlucosePackets: Bool = false,
        output: Output,
        makeAuthSession: @escaping (G7Link, G7PairingRecord) -> G7AuthSession = { link, record in
            G7AuthSession(link: link, slot: record.slot, pairingCode: record.pairingCode, savedKey: record.sharedKey.map { [UInt8]($0) })
        }
    ) {
        self.store = store
        self.diagnostics = diagnostics
        self.now = now
        self.mode = mode ?? .primary(slot: slot)
        self.recordsRawGlucosePackets = recordsRawGlucosePackets
        self.output = output
        self.makeAuthSession = makeAuthSession
        self.calibration = G7CalibrationQueue(
            emit: output.calibration,
            log: { message in diagnostics.record(DiagnosticEvent(date: now(), category: .sensor, message: "G7: " + message)) }
        )
    }

    /// Emits the first element of the state stream: what is known before any Bluetooth event.
    /// A store that cannot be read is a failure, never "not paired" (safety review M3).
    func emitInitialState() {
        switch loadRecordForMode() {
        case .failure:
            emit(.failed(G7FailureReason.credentialsUnavailable))
        case .success(nil):
            // Listen mode needs no pairing: it is about to look for the Dexcom app's connection.
            emit(isListening ? .searching : .notPaired)
        case .success(let stored?):
            record = stored
            if stored.requiresNewPairing {
                emit(.failed(G7FailureReason.savedKeyRejected))
            } else if let end = stored.sessionEnd {
                // Safety review N1: a latched end stays visible after a relaunch.
                lastSensorState = end.state
                emit(end.state)
            } else {
                emit(.searching)
            }
        }
    }

    /// D28: the session this source authenticated to, persisted across disconnects and relaunches;
    /// nil before the first `0x4E` of a pairing, after the grace-period end, after the sensor reported
    /// the session over (expired, failed, stopped) twice, 60 s of sensor time apart (N1, persisted), for an
    /// unsupported sensor, and when a new pairing is required.
    var currentSession: SensorSession? {
        guard let record, !record.requiresNewPairing, !record.sessionEnded,
              let serial = record.serial, let start = record.sessionStart,
              let parameters = reportedParameters(record) else { return nil }
        if let pipeline, pipeline.isUnsupportedSensor || pipeline.sessionEnded { return nil }
        let session = G7SensorLifetime.session(serial: serial, start: start, parameters: parameters)
        return now() <= session.gracePeriodEndsAt ? session : nil
    }

    /// A sensor this phone has authenticated to is stored, so `pairAgain(pairingCode:)` can target it.
    /// Always false in listen mode (no pairing there).
    var hasStoredSensor: Bool { !isListening && record?.serial != nil && record?.peripheralIdentifier != nil }

    /// The stored sensor's serial (`G7SensorSerial`), once this phone has authenticated to it
    /// (primary) or observed its authenticated connection (listen).
    var storedSensorSerial: String? {
        guard let record, record.serial != nil, record.peripheralIdentifier != nil else { return nil }
        return record.serial
    }

    /// Only for a sensor this app has authenticated to (serial fixed) and still may use. Nil in
    /// listen mode: this app does not own the connection, and the Trio handoff is off (D45).
    var heartbeatTarget: G7HeartbeatTarget? {
        guard !isListening, let record, record.serial != nil, !record.requiresNewPairing,
              let identifier = record.peripheralIdentifier else { return nil }
        return G7HeartbeatTarget(peripheralIdentifier: identifier)
    }

    // MARK: - Lifecycle

    /// Pairs a new sensor when `pairingCode` is given, otherwise resumes the stored pairing.
    ///
    /// A new pairing takes any G7 10-day sensor it finds, except sensors that refuse the code or do
    /// not connect, and except the previous sensor when its session has ended or it was unsupported
    /// (safety review M1, D37: a previous sensor that is still running may be the one being paired;
    /// `pairAgain(code:)` targets it explicitly).
    func start(pairingCode: String?) throws(G7StartError) {
        if isListening {
            guard pairingCode == nil else { throw .notAvailableInListenMode }
            try startListening()
            return
        }
        if let pairingCode {
            guard G7PairingCode.isValid(pairingCode) else { throw .invalidPairingCode }
            let previous = try? loadRecord().get()
            if let identifier = previous?.peripheralIdentifier { central?.cancelConnection(peripheralIdentifier: identifier) }
            finishCycle()
            calibration.cancelAll(reason: "A new sensor is being paired")
            let newRecord = G7PairingRecord(pairingCode: pairingCode, slot: slot)
            do { try store.save(newRecord) } catch {
                emit(.failed(G7FailureReason.credentialsUnavailable))
                throw .credentialStoreFailed("\(error)")
            }
            let previousIsFinished = previous.map { $0.sessionEnded || $0.isUnsupportedSensor } ?? false
            record = newRecord
            pipeline = nil
            lastSensorState = nil
            resetConnectionHistory()
            excludedIdentifiers = previousIsFinished ? Set([previous?.peripheralIdentifier].compactMap { $0 }) : []
            if !previousIsFinished, let previous, let identifier = previous.peripheralIdentifier {
                previousSensor = (previous.sensorName ?? "G7", identifier)
            }
            pairingStartedAt = now()
            let generation = pairingGeneration
            central?.schedule(after: Self.previousSensorSkipLimit) { [weak self] in
                self?.previousSensorSkipLimitReached(generation: generation)
            }
            log(.sensor, "pairing a new sensor in slot \(slot.rawValue)")
        } else {
            switch loadRecordForMode() {
            case .failure(let error):
                emit(.failed(G7FailureReason.credentialsUnavailable))
                throw .credentialStoreFailed("\(error)")
            case .success(let stored):
                record = stored
            }
        }
        resume()
    }

    /// "Pair again" (D37): a full J-PAKE with `pairingCode` against the stored sensor, for when the
    /// sensor refused this phone (`pairingRejected`) or the key must be replaced. The sensor's
    /// identity, serial, session start, published-reading history and any session end are kept;
    /// only the code and key change (the new key is saved once the sensor confirms ownership). It
    /// claims the phone's slot again, so another collector in the same slot loses it (the user's
    /// explicit choice; automatic reconnection never does this, §3.1).
    func pairAgain(pairingCode: String) throws(G7StartError) {
        guard !isListening else { throw .notAvailableInListenMode }
        guard G7PairingCode.isValid(pairingCode) else { throw .invalidPairingCode }
        let stored: G7PairingRecord?
        switch loadRecordForMode() {
        case .failure(let error):
            emit(.failed(G7FailureReason.credentialsUnavailable))
            throw .credentialStoreFailed("\(error)")
        case .success(let loaded):
            stored = loaded
        }
        guard var updated = stored, updated.serial != nil, updated.peripheralIdentifier != nil else {
            throw .noSensorToPairAgain
        }
        finishCycle()
        calibration.cancelAll(reason: "The sensor is being paired again")
        updated.pairingCode = pairingCode
        updated.sharedKey = nil // no saved key: the next connection runs the full J-PAKE (§3.2)
        updated.requiresNewPairing = false
        do { try store.save(updated) } catch {
            emit(.failed(G7FailureReason.credentialsUnavailable))
            throw .credentialStoreFailed("\(error)")
        }
        record = updated
        lastSensorState = updated.sessionEnd?.state // show progress (searching, authenticating) again
        resetConnectionHistory()
        log(.sensor, "pairing \(updated.sensorName ?? "the sensor") again in slot \(updated.slot.rawValue)")
        resume()
    }

    /// A new or repeated pairing starts without the previous connections' history.
    private func resetConnectionHistory() {
        rejectionAfterAuthenticationStreak = 0
        lastPipelineFailure = nil
        candidate = nil
        excludedIdentifiers = []
        previousSensor = nil
        pairingStartedAt = nil
        skippedPreviousSensorRefusal = false
        pairingGeneration += 1
        listenCandidate = nil
        listenConnectionsWithoutAuthentication = 0
        listenWakesWithProof = 0
        listenRetryDelay = 0
        listenRetryGeneration += 1
        listenRetryPending = false
        listenAttachInFlight = false
    }

    /// The common tail of `start` and `pairAgain`: run with the current record.
    private func resume() {
        isRunning = true
        guard let record else {
            emit(.notPaired)
            return
        }
        if record.requiresNewPairing {
            emit(.failed(G7FailureReason.savedKeyRejected))
            return
        }
        if let end = record.sessionEnd { lastSensorState = end.state }
        if let power = G7SensorStatus.state(for: bluetoothPower) {
            emit(power)
            return
        }
        if let end = record.sessionEnd { emit(end.state) }
        connectIfPossible()
    }

    func stop() {
        isRunning = false
        listenAttachInFlight = false
        central?.stopScanning()
        // In listen mode this cancels only this app's use of the Dexcom app's link; iOS keeps the
        // physical link for the Dexcom app (CBCentralManager.cancelPeripheralConnection).
        if let identifier = cycle?.link.peripheralIdentifier ?? listenCycle?.link.peripheralIdentifier ?? record?.peripheralIdentifier {
            central?.cancelConnection(peripheralIdentifier: identifier)
        }
        finishCycle()
        log(.ble, "stopped")
    }

    /// Forget sensor: stop, delete the pairing record (key and code), report `.notPaired`.
    func forget() {
        stop()
        calibration.cancelAll(reason: "The sensor was forgotten")
        do { try store.delete() } catch { log(.sensor, "could not delete the pairing record: \(error)") }
        record = nil
        pipeline = nil
        lastSensorState = nil
        resetConnectionHistory()
        log(.sensor, "sensor forgotten")
        emit(.notPaired)
    }

    // MARK: - Backfill floor (audit m1)

    /// The app reports the newest reading it has durably stored for the sensor `serial` (nil: none of
    /// that sensor's readings is stored). Backfill records the sensor sends for later sensor times are
    /// published again even if G7Kit already published them (same id and date). A reading of another
    /// sensor, or one whose id is not this sensor's `GlucoseReading.sensorID`, is ignored (logged).
    func setLatestStoredReading(_ reading: GlucoseReading?, serial: String) {
        let floor: G7ReadingPipeline.BackfillFloor
        if let reading {
            guard reading.sensorSerial == serial, let timestamp = Self.sensorTimestamp(of: reading, serial: serial) else {
                log(.sensor, "backfill floor: reading \(reading.id) is not a reading of \(serial); ignored")
                return
            }
            floor = .storedThrough(sensorTimestamp: timestamp)
        } else {
            floor = .nothingStored
        }
        if backfillFloor?.serial != serial || backfillFloor?.floor != floor {
            log(.sensor, "backfill floor for \(serial): \(floor)")
        }
        backfillFloor = (serial, floor)
        applyBackfillFloor()
    }

    /// The sensor timestamp encoded in a G7Kit reading id (`GlucoseReading.sensorID`), verified by
    /// rebuilding the id.
    static func sensorTimestamp(of reading: GlucoseReading, serial: String) -> UInt32? {
        let prefix = serial + ":"
        guard reading.id.hasPrefix(prefix), let timestamp = UInt32(reading.id.dropFirst(prefix.count)),
              GlucoseReading.sensorID(serial: serial, sensorTimestamp: timestamp) == reading.id else { return nil }
        return timestamp
    }

    /// A floor applies only to the pipeline of the same serial (never across sensors or sessions).
    private func applyBackfillFloor() {
        guard let pipeline else { return }
        pipeline.backfillFloor = backfillFloor?.serial == pipeline.serial ? backfillFloor?.floor : nil
    }

    // MARK: - Calibration

    func submitCalibration(_ request: CalibrationRequest) throws(CalibrationRefusal) {
        guard !isListening else {
            // Listen mode never sends calibrations (D45, D49): this app is not authenticated with it.
            log(.sensor, "calibration refused: listen mode does not write to the sensor")
            throw .notAuthenticated
        }
        let context = G7CalibrationQueue.Context(
            isPaired: record != nil,
            isAuthenticated: record?.sharedKey != nil && record?.requiresNewPairing == false && pipeline?.isUnsupportedSensor == false,
            sensorState: lastSensorState,
            clockMismatch: lastPipelineFailure == .clockMismatch
        )
        try calibration.submit(request, context: context, now: now())
    }

    // MARK: - Central events

    func bluetoothPowerChanged(_ power: G7BluetoothPower) {
        bluetoothPower = power
        log(.ble, "Bluetooth \(power)")
        if let unavailable = G7SensorStatus.state(for: power) {
            // S5: radio off / permission denied is always visible. CoreBluetooth drops every
            // connection without a didDisconnect callback in this case, so end the cycle here.
            finishCycle()
            emit(unavailable)
            return
        }
        guard power == .poweredOn, isRunning else { return }
        // Review N1: every connection is new after Bluetooth returns; a listen-mode backoff from
        // before must not leave the app without a pending connection.
        clearListenRetry()
        if let lastSensorState {
            emit(lastSensorState)
        } else if record == nil {
            emit(.notPaired)
        }
        connectIfPossible()
    }

    func didDiscover(name: String?, identifier: UUID) {
        if isListening {
            if let name, Self.isG7AdvertisedName(name) { advertisedG7Names[identifier] = name }
            listenDidDiscover(identifier: identifier)
            return
        }
        guard isRunning, cycle == nil, let record, !record.requiresNewPairing, let name else { return }
        if let knownName = record.sensorName {
            // Reconnecting a paired sensor that iOS could not retrieve by identifier.
            guard name == knownName else { return }
        } else {
            // New pairing: any G7 10-day sensor except the old one and ones that refused the code.
            guard name.hasPrefix(G7GATT.sensorNamePrefix), !excludedIdentifiers.contains(identifier) else { return }
        }
        candidate = (name, identifier)
        candidateAttempt += 1
        let attempt = candidateAttempt
        log(.ble, "found \(name); connecting")
        central?.stopScanning()
        _ = central?.connect(peripheralIdentifier: identifier)
        central?.schedule(after: Self.candidateConnectTimeout) { [weak self] in
            self?.candidateTimedOut(attempt: attempt)
        }
    }

    /// The link is connected and its characteristics are discovered.
    func didConnect(link: G7Link, availableCharacteristics: Set<G7Characteristic>) {
        if isListening {
            listenDidConnect(link: link, availableCharacteristics: availableCharacteristics)
            return
        }
        guard isRunning, let record, !record.requiresNewPairing else {
            link.disconnect()
            return
        }
        let expected = [record.peripheralIdentifier, candidate?.identifier].compactMap { $0 }
        guard expected.contains(link.peripheralIdentifier) else {
            log(.ble, "connection from an unexpected peripheral ignored")
            link.disconnect()
            return
        }
        candidateAttempt += 1 // the connect timeout no longer applies
        finishCycle()
        log(.ble, "connected")
        emitTransient(.authenticating)
        pipeline?.beginConnection()
        calibration.beginConnection()
        let newCycle = G7ConnectionCycle(link: link, auth: makeAuthSession(link, record))
        newCycle.delegate = self
        cycle = newCycle
        newCycle.start(availableCharacteristics: availableCharacteristics)
    }

    /// Review m7: CoreBluetooth events carry their peripheral; one for a peripheral that is not the
    /// current connection is dropped (defence in depth; G7CoreBluetoothCentral calls these).
    func notificationStateChanged(for characteristic: G7Characteristic, isNotifying: Bool, error: G7LinkError?, from identifier: UUID) {
        guard isCurrentConnection(identifier) else { return }
        notificationStateChanged(for: characteristic, isNotifying: isNotifying, error: error)
    }

    func valueUpdated(for characteristic: G7Characteristic, value: Data, from identifier: UUID) {
        guard isCurrentConnection(identifier) else {
            log(.ble, "value from a peripheral that is not the current connection dropped")
            return
        }
        valueUpdated(for: characteristic, value: value)
    }

    func writeFailed(for characteristic: G7Characteristic, error: G7LinkError, from identifier: UUID) {
        guard isCurrentConnection(identifier) else { return }
        writeFailed(for: characteristic, error: error)
    }

    private func isCurrentConnection(_ identifier: UUID) -> Bool {
        cycle?.link.peripheralIdentifier == identifier || listenCycle?.link.peripheralIdentifier == identifier
    }

    func notificationStateChanged(for characteristic: G7Characteristic, isNotifying: Bool, error: G7LinkError?) {
        if let listenCycle {
            listenCycle.notificationStateChanged(for: characteristic, isNotifying: isNotifying, error: error)
            return
        }
        cycle?.notificationStateChanged(for: characteristic, isNotifying: isNotifying, error: error)
    }

    func valueUpdated(for characteristic: G7Characteristic, value: Data) {
        recordRawGlucosePacketIfEnabled(characteristic, value)
        if let listenCycle {
            listenCycle.valueUpdated(for: characteristic, value: value)
            return
        }
        cycle?.valueUpdated(for: characteristic, value: value)
    }

    /// A write failure belongs to a primary cycle, or to listen mode's one `52` query, which is not
    /// retried in that connection (D49).
    func writeFailed(for characteristic: G7Characteristic, error: G7LinkError) {
        cycle?.writeFailed(for: characteristic, error: error)
    }

    /// The sensor disconnected (normal after each ~5-minute exchange) or the link dropped.
    func didDisconnect(peripheralIdentifier: UUID) {
        guard isExpected(peripheralIdentifier) else {
            log(.ble, "disconnect of an unrelated peripheral ignored")
            return
        }
        if isListening {
            listenDidDisconnect()
            return
        }
        let sessionLengthUnanswered = cycle?.isAwaitingSessionLength == true
        finishCycle()
        if sessionLengthUnanswered {
            // Safety review P7: `52` was never answered, so no GetData was sent; say why nothing came.
            log(.sensor, "the sensor did not answer the session-length request before disconnecting")
            emit(.failed(G7FailureReason.sessionLengthUnknown))
        }
        guard isRunning, let record, !record.requiresNewPairing else { return }
        if let known = record.peripheralIdentifier {
            // Keep a pending connection so iOS reconnects at the next advertisement, even in the
            // background (BluetoothTransmitter.swift:313-317; 7.1.1 commit 00c144e8 relies on the
            // same pending request for coexistence).
            if !(central?.connect(peripheralIdentifier: known) ?? false) { central?.scanForSensors() }
        } else {
            // New pairing did not complete with this sensor: keep scanning.
            candidate = nil
            central?.scanForSensors()
        }
    }

    /// Connection attempt failed: ask again (BluetoothTransmitter.swift:837-848).
    func didFailToConnect(peripheralIdentifier: UUID) {
        guard isExpected(peripheralIdentifier) else { return }
        if isListening {
            // Review m3: only the followed sensor is retried (with the m6 backoff); a candidate that
            // failed is dropped and looked for again on the Dexcom app's connection.
            listenCandidate = nil
            listenAttachInFlight = false
            log(.ble, "listen: connection attempt failed")
            if peripheralIdentifier == record?.peripheralIdentifier { listenAttachFailed() }
            return
        }
        log(.ble, "connection attempt failed; retrying")
        guard isRunning, record?.requiresNewPairing == false else { return }
        _ = central?.connect(peripheralIdentifier: peripheralIdentifier)
    }

    // MARK: - G7ConnectionCycleDelegate

    func cycleDidAuthenticate(newlyConfirmedKey: [UInt8]?) {
        guard var current = record, let link = cycle?.link else { return }
        if current.serial == nil {
            // First authenticated connection of this pairing: fix the identity and the serial.
            let name = candidate?.name ?? current.sensorName ?? link.peripheralName ?? "G7"
            current.sensorName = name
            current.serial = G7SensorSerial.make(sensorName: name, peripheralIdentifier: link.peripheralIdentifier)
            excludedIdentifiers = []
            previousSensor = nil
            skippedPreviousSensorRefusal = false
            log(.sensor, "paired with \(name), serial \(current.serial ?? "?")")
        }
        candidate = nil
        // A paired sensor found again by name can come back under a new iOS identifier; reconnect to
        // that one from now on. The serial never changes (reading ids stay stable).
        current.peripheralIdentifier = link.peripheralIdentifier
        if let key = newlyConfirmedKey {
            current.sharedKey = Data(key)
            log(.sensor, "ownership confirmed; key saved for short authentication")
        }
        saveRecord(current)
        if let serial = current.serial, pipeline?.serial != serial {
            pipeline = G7ReadingPipeline(
                serial: serial,
                reportedParameters: reportedParameters(current),
                sessionStart: current.sessionStart,
                sessionEnd: current.sessionEnd,
                unconfirmedEnd: current.unconfirmedSessionEnd,
                newestReading: current.newestReading
            ) { [weak self] message in
                self?.log(.sensor, message)
            }
            pipeline?.beginConnection()
            applyBackfillFloor()
        }
        connectionAuthenticated = true
        log(.ble, "authenticated")
    }

    func cycleSavedKeyRejected() {
        guard var current = record else { return }
        rejectionAfterAuthenticationStreak = 0
        current.requiresNewPairing = true
        saveRecord(current)
        log(.sensor, "saved key rejected; automatic reconnection stopped")
        emit(.failed(G7FailureReason.savedKeyRejected))
        cycle?.link.disconnect()
    }

    /// B1: a rejection seen after we authenticated may be the sensor revoking our key or another app
    /// failing on the shared link. N2: this connection is finished at once (the auth session has
    /// already stopped forwarding; backfill not yet published is discarded), then the disconnect is
    /// requested. The next connection's own, solicited status decides whether the key is really gone
    /// (then `requiresNewPairing` and "Pair again"). P9: while our own authentication keeps succeeding
    /// and the rejection recurs, the reason names the likely cause instead.
    func cycleSawRejectionAfterAuthentication() {
        guard let ending = cycle else { return }
        rejectionAfterAuthenticationStreak += 1
        connectionRejectedAfterAuthentication = true
        let reason = rejectionAfterAuthenticationStreak >= 2
            ? G7FailureReason.otherAppRejected
            : G7FailureReason.rejectedAfterAuthentication
        log(.sensor, "authentication rejection after authenticating (\(rejectionAfterAuthenticationStreak) in a row); connection ended, key re-checked next time")
        pipeline?.discardConnection()
        finishCycle()
        emit(.failed(reason))
        ending.link.disconnect()
    }

    func cycleNeedsFullBootstrap() {
        guard var current = record else { return }
        current.sharedKey = nil
        saveRecord(current)
        log(.sensor, "sensor reports incomplete ownership; full pairing at the next connection")
        cycle?.link.disconnect()
    }

    func cycleAuthFailed(_ failure: G7AuthFailure) {
        log(.sensor, "authentication failed: \(failure)")
        switch failure {
        case .pairingCodeRejected:
            if let candidate, record?.peripheralIdentifier == nil {
                excludedIdentifiers.insert(candidate.identifier)
                if let previousSensor, candidate.identifier == previousSensor.identifier {
                    // The user is pairing a new sensor and the previous, still running one (same
                    // CoreBluetooth identifier, never just the same name) answered first: its refusal
                    // of the new code is expected. `.failed(pairingCodeRejected)` would raise the
                    // sensor alert, a false alarm here, so it is skipped within the time limit.
                    if let started = pairingStartedAt, now().timeIntervalSince(started) < Self.previousSensorSkipLimit {
                        skippedPreviousSensorRefusal = true
                        log(.sensor, "the previous sensor \(previousSensor.name) did not accept the new code; skipped, still looking for the new sensor")
                    } else {
                        log(.sensor, "the previous sensor \(previousSensor.name) did not accept the new code after the skip limit")
                        emit(.failed(G7FailureReason.previousSensorRejectedCode(sensorName: previousSensor.name)))
                    }
                    cycle?.link.disconnect()
                    return
                }
            } else if var current = record {
                current.requiresNewPairing = true
                saveRecord(current)
            }
            emit(.failed(G7FailureReason.pairingCodeRejected))
        case .missingPairingCode:
            emit(.failed(G7FailureReason.pairingCodeNeeded))
        case .pakeRejectedBySensor, .pake, .certificateExchangeRejected, .proofRejected, .protocolError:
            emit(.failed(G7FailureReason.authenticationFailed))
        }
        cycle?.link.disconnect()
    }

    func cycleLinkFailed(_ error: G7LinkError) {
        switch error {
        case .pairingNotCompleted:
            emit(.failed(G7FailureReason.bluetoothPairingNotCompleted))
        case .bondRemovedBySensor:
            emit(.failed(G7FailureReason.bondRemovedBySensor))
        case .other:
            return
        }
        cycle?.link.disconnect()
    }

    func cycleNeedsSessionLength() -> Bool {
        record?.reportedSessionLength == nil
    }

    func cycleReceivedGlucose(_ message: G7GlucoseMessage) {
        handleGlucoseReport(message, receivedAt: now())
    }

    /// A glucose report from the primary cycle or (D45) the listen cycle: the same pipeline, gate and
    /// state handling for both.
    private func handleGlucoseReport(_ report: some G7GlucoseReport, receivedAt: Date) {
        guard let pipeline else { return }
        var result = pipeline.handleGlucose(report, receivedAt: receivedAt)
        if isListening, result.state == .failed(G7FailureReason.sessionLengthUnknown) {
            result.state = .failed(G7FailureReason.listenSessionLengthUnknown)
        }
        if let end = pipeline.sessionEnd {
            // N1: the latched end is the sensor's state from now on (also for Bluetooth-on and calibration).
            lastSensorState = end.state
        } else if let state = result.state {
            if case .failed = state {} else { lastSensorState = state }
        }
        apply(result)
    }

    func cycleReceivedBackfillFrame(_ frame: Data) {
        pipeline?.handleBackfillFrame(frame, now: now())
    }

    func cycleBackfillFinished() {
        guard let pipeline else { return }
        apply(pipeline.flushBackfill())
    }

    func cycleReceivedExtendedVersion(_ message: G7ExtendedVersionMessage) {
        guard let pipeline, var current = record else { return }
        let result = pipeline.handleExtendedVersion(message)
        log(.sensor, "session length \(message.sessionLength) s, warm-up \(message.warmUpDuration) s")
        if let state = result.state {
            lastSensorState = state
            emit(state)
        }
        if pipeline.isUnsupportedSensor {
            // Remembered so a later new-sensor pairing ignores this sensor (M1).
            if !current.isUnsupportedSensor {
                current.isUnsupportedSensor = true
                saveRecord(current)
            }
        } else {
            current.reportedSessionLength = message.sessionLength
            current.reportedWarmUp = message.warmUpDuration
            saveRecord(current)
        }
    }

    func cycleReceivedCalibrationResponse(_ response: G7CalibrationCommandResponse) {
        calibration.handleCommandResponse(response, now: now())
    }

    func cycleReceivedCalibrationRecord(_ record: G7CalibrationBounds) {
        calibration.handleBounds(record)
    }

    /// Calibration work after the reading (CGMG7Transmitter.swift:1237-1248); `52` is requested
    /// before GetData instead (G7ConnectionCycle). Battery/firmware requests are not ported.
    func cycleNextControlRequest() -> Data? {
        guard let pipeline, let clock = pipeline.clock, !pipeline.isUnsupportedSensor, !pipeline.sessionEnded else { return nil }
        return calibration.nextCommand(clock: clock, now: now())
    }

    /// A failed calibration write is queued again and the connection dropped (CGMG7Transmitter.swift:793-807).
    func cycleControlWriteFailed(_ request: Data) {
        log(.ble, "control write \(request.hexString) failed")
        if request.first == G7Opcode.calibrate.rawValue {
            calibration.commandWriteFailed()
            cycle?.link.disconnect()
        }
    }

    func cycleLog(_ message: String) {
        log(.ble, message)
    }

    // MARK: - Mode and raw recording (D45, D47)

    /// Switches between primary and listen mode (the app's explicit choice, never automatic). Stops,
    /// drops every stored pairing and session (code, key, sensor, session, latched end) and starts
    /// over in `newMode`: `.notPaired` for primary, `.searching` for listen. Call `start` afterwards.
    func setMode(_ newMode: G7ConnectionMode) throws(G7StartError) {
        guard newMode != mode else { return }
        stop()
        calibration.cancelAll(reason: "The sensor connection mode changed")
        do { try store.delete() } catch {
            emit(.failed(G7FailureReason.credentialsUnavailable))
            throw .credentialStoreFailed("\(error)")
        }
        record = nil
        pipeline = nil
        lastSensorState = nil
        resetConnectionHistory()
        let previous = mode
        mode = newMode
        log(.sensor, "mode changed from \(previous.summary) to \(newMode.summary); stored pairing and session dropped")
        emit(isListening ? .searching : .notPaired)
    }

    /// D47: every received glucose packet (`0x4E`; in listen mode also `0x31` and `0x25`), valid or
    /// not, is logged as hex with its time when recording is on. These packets carry no pairing code
    /// or key.
    private func recordRawGlucosePacketIfEnabled(_ characteristic: G7Characteristic, _ value: Data) {
        guard recordsRawGlucosePackets, characteristic == .writeControl, let opcode = value.first else { return }
        let glucoseOpcodes: Set<UInt8> = isListening
            ? [G7Opcode.glucose.rawValue, G7Opcode.coexistenceGlucose.rawValue, G7Opcode.transmitterTime.rawValue]
            : [G7Opcode.glucose.rawValue]
        guard glucoseOpcodes.contains(opcode) else { return }
        log(.sensor, "raw \(isListening ? "listen" : "primary") packet \(value.hexString)")
    }

    // MARK: - Listen mode (D45, D49)
    //
    // Ported policy: CGMG7Transmitter.swift coexistence — attach to the connection the Dexcom app made
    // (retrieveConnectedPeripherals, :553-571, :2082-2087), observe. Deviation: once the sensor is
    // followed, a pending connection request to it keeps this app awake at every sensor wake, as
    // primary mode does (BluetoothTransmitter.swift:313-317) and as the 7.1.1 coexistence fix 00c144e8
    // relies on; iOS shares the one physical link with the Dexcom app. The only write is the one `52`
    // session-length query per connection under the D49 conditions (`G7SessionLengthQuery`); the
    // listen cycle's link has no other write, and calibration is refused above.

    /// Start (or resume) listening: no pairing code; an empty listen record is created if needed.
    private func startListening() throws(G7StartError) {
        switch loadRecordForMode() {
        case .failure(let error):
            emit(.failed(G7FailureReason.credentialsUnavailable))
            throw .credentialStoreFailed("\(error)")
        case .success(let stored?):
            record = stored
        case .success(nil):
            let fresh = G7PairingRecord.forListening()
            do { try store.save(fresh) } catch {
                emit(.failed(G7FailureReason.credentialsUnavailable))
                throw .credentialStoreFailed("\(error)")
            }
            record = fresh
            log(.sensor, "listen mode: looking for the Dexcom app's connection to a G7")
        }
        resume()
    }

    private func listenConnectIfPossible() {
        guard isRunning, record != nil, bluetoothPower == .poweredOn, listenCycle == nil else { return }
        emitTransient(.searching)
        listenReconnect()
    }

    /// Follows the sensor (pending connection) or looks for the Dexcom app's connection. Emits no
    /// state, so a failure just reported at a disconnect stays visible (S5).
    private func listenReconnect() {
        guard isRunning, let record, bluetoothPower == .poweredOn, listenCycle == nil, !listenRetryPending else { return }
        if let identifier = record.peripheralIdentifier, central?.connect(peripheralIdentifier: identifier) == true {
            listenAttachInFlight = true
            log(.ble, "listen: waiting for the Dexcom app's next connection to \(record.sensorName ?? "the sensor")")
            return
        }
        attachToSystemConnectedSensor()
        // Scanning is only a wake-up signal here (CGMG7Transmitter.swift:562-571): advertisements are
        // never connected to directly, which could take the sensor's connection from its owner.
        central?.scanForSensors()
        scheduleListenSearch()
    }

    private func listenDidDiscover(identifier: UUID) {
        guard isRunning, listenCycle == nil, let record else { return }
        if listenRetryPending, identifier == record.peripheralIdentifier {
            // Review N1/N1b: an advertisement of the followed sensor is a new sensor wake (and may be
            // what woke the suspended app). End the backoff and attach now — also if the Dexcom app's
            // pending connection already reconnected it by the time this runs. One attach per
            // advertisement cannot loop; if it fails, `listenAttachFailed` restarts the scan again.
            log(.ble, "listen: the followed sensor advertises; backoff ended")
            endListenBackoff(resettingLevel: false) // the level grows again if this attach fails too
            listenReconnect()
            return
        }
        attachToSystemConnectedSensor()
    }

    /// The followed sensor is connected to this phone right now by another app (the Dexcom app).
    private func followedSensorIsSystemConnected() -> Bool {
        guard let followed = record?.peripheralIdentifier else { return false }
        return central?.connectedSensors().contains { $0.identifier == followed } ?? false
    }

    /// Review m6 + N1: a connect or attach to the followed sensor failed before a cycle could start.
    /// While the Dexcom app holds the link, back off (no tight loop on its link) and keep a freshly
    /// started scan, whose discovery of the next advertisement can wake a suspended app. Otherwise
    /// arm the pending connection at once, so iOS wakes the app at the sensor's next advertisement.
    private func listenAttachFailed() {
        if followedSensorIsSystemConnected() {
            scheduleListenRetry()
            central?.restartScan() // so the next advertisement is a new discovery event
        } else {
            clearListenRetry()
            listenReconnect()
        }
    }

    private func clearListenRetry() {
        endListenBackoff(resettingLevel: true)
    }

    private func endListenBackoff(resettingLevel: Bool) {
        if resettingLevel { listenRetryDelay = 0 }
        listenRetryPending = false
        listenRetryGeneration += 1
        listenAttachInFlight = false
    }

    /// Attach to a G7 that the Dexcom app has connected right now: the followed sensor once known,
    /// otherwise the first such G7.
    private func attachToSystemConnectedSensor() {
        guard isRunning, listenCycle == nil, listenCandidate == nil, !listenRetryPending, !listenAttachInFlight, let record else { return }
        for sensor in central?.connectedSensors() ?? [] {
            let name: String
            if let followed = record.peripheralIdentifier {
                guard sensor.identifier == followed else { continue }
                name = record.sensorName ?? sensor.name ?? "G7"
            } else {
                guard let g7Name = g7Name(of: sensor) else {
                    log(.ble, "listen: connected peripheral \(sensor.name ?? "without a name") is not a G7 seen advertising; not attached")
                    continue
                }
                name = g7Name
            }
            listenCandidate = G7ConnectedSensor(name: name, identifier: sensor.identifier)
            listenAttachInFlight = true
            log(.ble, "listen: attaching to the Dexcom app's connection to \(name)")
            _ = central?.connect(peripheralIdentifier: sensor.identifier)
            return
        }
    }

    /// Review m4: the advertised G7 name ("DXCM" + 2 characters) of a system-connected peripheral,
    /// or nil if it cannot be shown to be a G7. A connected G7 may report "Dexcom" + 2 characters
    /// (G7SensorKit G7Sensor.swift:246-247), the name a G6 uses too, so that form is accepted only
    /// for a peripheral this app saw advertising as "DXCM" + 2 (G6 transmitters advertise as
    /// "Dexcom…"). ONE+ ("DX02…") and Stelo ("DX01…") never match.
    private func g7Name(of sensor: G7ConnectedSensor) -> String? {
        guard let name = sensor.name else { return advertisedG7Names[sensor.identifier] }
        if Self.isG7AdvertisedName(name) { return name }
        if name.hasPrefix("Dexcom"), name.count == "Dexcom".count + 2 { return advertisedG7Names[sensor.identifier] }
        return nil
    }

    /// "DXCM" + exactly 2 characters (CGMG7Transmitter.swift name check; G7SensorKit G7Sensor.swift:248).
    static func isG7AdvertisedName(_ name: String) -> Bool {
        name.hasPrefix(G7GATT.sensorNamePrefix) && name.count == G7GATT.sensorNamePrefix.count + 2
    }

    /// Review m6: retry the followed sensor (or the search) after a backoff, doubling to 5 min; no
    /// other path attaches while it is pending. The level is kept until a connection gets a cycle.
    private func scheduleListenRetry() {
        listenRetryDelay = listenRetryDelay == 0 ? Self.listenRetryInitialDelay : min(listenRetryDelay * 2, Self.listenRetryMaximumDelay)
        listenRetryGeneration += 1
        let generation = listenRetryGeneration
        listenRetryPending = true
        log(.ble, "listen: attach failed; next attempt in \(Int(listenRetryDelay)) s")
        central?.schedule(after: listenRetryDelay) { [weak self] in
            guard let self, generation == self.listenRetryGeneration else { return }
            self.listenRetryPending = false
            self.listenReconnect()
        }
    }

    private func scheduleListenSearch() {
        guard !listenSearchScheduled, record?.peripheralIdentifier == nil else { return }
        listenSearchScheduled = true
        central?.schedule(after: Self.listenSearchInterval) { [weak self] in
            guard let self else { return }
            self.listenSearchScheduled = false
            guard self.isListening, self.isRunning, self.listenCycle == nil, self.record?.peripheralIdentifier == nil else { return }
            self.listenCandidate = nil
            self.attachToSystemConnectedSensor()
            // Review m4: until the first follow, restart the scan so the sensor's next advertisement is
            // a new discovery (with its "DXCM" name); foreground only — timers do not run suspended.
            self.central?.restartScan()
            self.scheduleListenSearch()
        }
    }

    private func listenDidConnect(link: G7Link, availableCharacteristics: Set<G7Characteristic>) {
        guard isRunning, let record else {
            central?.cancelConnection(peripheralIdentifier: link.peripheralIdentifier)
            return
        }
        let expected = [record.peripheralIdentifier, listenCandidate?.identifier].compactMap { $0 }
        guard expected.contains(link.peripheralIdentifier) else {
            log(.ble, "listen: connection from an unexpected peripheral ignored")
            central?.cancelConnection(peripheralIdentifier: link.peripheralIdentifier)
            return
        }
        listenAttachInFlight = false
        finishCycle()
        log(.ble, "listen: attached; waiting to observe the Dexcom app's authentication")
        emitTransient(.authenticating)
        pipeline?.beginConnection()
        let newCycle = G7ListenCycle(link: link, sessionLengthQuery: G7SessionLengthQuery(link: link), now: now)
        newCycle.delegate = self
        listenConnectionHadCycle = true
        listenCycle = newCycle
        newCycle.start(availableCharacteristics: availableCharacteristics)
    }

    private func listenDidDisconnect() {
        let observed = listenCycle?.observedAuthenticationThisConnection
        let hadCycle = listenConnectionHadCycle
        listenConnectionHadCycle = false
        listenAttachInFlight = false
        finishCycle()
        listenCandidate = nil
        if observed == false {
            listenConnectionsWithoutAuthentication += 1
            log(.sensor, "listen: no authenticated Dexcom app connection observed (\(listenConnectionsWithoutAuthentication) in a row)")
            if listenConnectionsWithoutAuthentication >= Self.listenUnauthenticatedConnectionsBeforeSurfacing {
                emit(.failed(G7FailureReason.listenNoAuthenticatedConnection))
            }
        }
        guard isRunning, record != nil else { return }
        if hadCycle {
            listenRetryDelay = 0
            listenReconnect()
        } else if record?.peripheralIdentifier != nil {
            // The link went down before a cycle could start (e.g. service discovery failed).
            listenAttachFailed()
        } else {
            // First follow: the candidate was the Dexcom app's link; back off before reattaching (m6).
            scheduleListenRetry()
        }
    }

    // MARK: - G7ListenCycleDelegate

    func listenCycleObservedAuthentication() {
        guard var current = record, let link = listenCycle?.link else { return }
        listenConnectionsWithoutAuthentication = 0
        if current.serial == nil {
            listenWakesWithProof = 0
            // First observed authenticated connection: follow this sensor from now on.
            let name = listenCandidate?.name ?? link.peripheralName ?? "G7"
            current.sensorName = name
            current.peripheralIdentifier = link.peripheralIdentifier
            current.serial = G7SensorSerial.make(sensorName: name, peripheralIdentifier: link.peripheralIdentifier)
            saveRecord(current)
            log(.sensor, "listen mode: following \(name), serial \(current.serial ?? "?")")
        }
        listenCandidate = nil
        listenWakesWithProof += 1
        if let serial = current.serial, pipeline?.serial != serial {
            pipeline = G7ReadingPipeline(
                serial: serial,
                reportedParameters: reportedParameters(current),
                sessionStart: current.sessionStart,
                sessionEnd: current.sessionEnd,
                unconfirmedEnd: current.unconfirmedSessionEnd,
                newestReading: current.newestReading
            ) { [weak self] message in
                self?.log(.sensor, message)
            }
            pipeline?.beginConnection()
        }
        log(.ble, "listen: the Dexcom app's authenticated connection observed (wake \(listenWakesWithProof) with proof)")
    }

    /// D49: the session length must come from the sensor. Observed `52` answers (Trio's G7SensorKit
    /// or the Dexcom app asking) come first; only if none was seen by the second wake with proof may
    /// this app ask once per connection.
    func listenCycleShouldQuerySessionLength() -> Bool {
        guard isListening, let record, record.serial != nil, record.reportedSessionLength == nil,
              !record.isUnsupportedSensor, pipeline?.isUnsupportedSensor != true, !record.sessionEnded else { return false }
        return listenWakesWithProof >= Self.listenWakesBeforeSessionLengthQuery
    }

    /// As primary mode's N2: nothing more from this connection; this app does not disconnect the
    /// Dexcom app's link.
    func listenCycleSawRejectionAfterAuthentication() {
        log(.sensor, "listen: authentication rejection observed after authentication; this connection is not used")
        pipeline?.discardConnection()
        finishCycle()
        emit(.failed(G7FailureReason.listenConnectionRejected))
    }

    func listenCycleReceivedGlucose(_ report: any G7GlucoseReport, receivedAt: Date) {
        handleGlucoseReport(report, receivedAt: receivedAt)
    }

    func listenCycleReceivedExtendedVersion(_ message: G7ExtendedVersionMessage) {
        cycleReceivedExtendedVersion(message)
    }

    func listenCycleLog(_ message: String) {
        log(.ble, message)
    }

    // MARK: - Private

    private func connectIfPossible() {
        if isListening {
            listenConnectIfPossible()
            return
        }
        guard isRunning, let record, !record.requiresNewPairing, bluetoothPower == .poweredOn, cycle == nil else { return }
        emitTransient(.searching)
        if let identifier = record.peripheralIdentifier, central?.connect(peripheralIdentifier: identifier) == true {
            log(.ble, "waiting for the sensor to advertise")
            return
        }
        log(.ble, "scanning for the sensor")
        central?.scanForSensors()
    }

    /// The candidate never connected: give it up (new pairing: never try it again) and scan.
    private func candidateTimedOut(attempt: Int) {
        guard attempt == candidateAttempt, cycle == nil, let timedOut = candidate else { return }
        candidate = nil
        if record?.sensorName == nil { excludedIdentifiers.insert(timedOut.identifier) }
        central?.cancelConnection(peripheralIdentifier: timedOut.identifier)
        log(.ble, "\(timedOut.name) did not connect within \(Int(Self.candidateConnectTimeout)) s; scanning again")
        guard isRunning else { return }
        connectIfPossible()
    }

    /// Re-review N1: a skipped refusal by the previous sensor must not stay hidden. If no sensor has
    /// authenticated in this pairing by the limit, it is reported, naming the previous sensor.
    private func previousSensorSkipLimitReached(generation: Int) {
        guard generation == pairingGeneration, isRunning, record?.serial == nil,
              skippedPreviousSensorRefusal, let previousSensor else { return }
        log(.sensor, "no sensor accepted the code within \(Int(Self.previousSensorSkipLimit)) s; \(previousSensor.name) refused it")
        emit(.failed(G7FailureReason.previousSensorRejectedCode(sensorName: previousSensor.name)))
    }

    /// Events about peripherals other than the paired sensor or the current candidate are ignored.
    private func isExpected(_ identifier: UUID) -> Bool {
        if let cycle { return cycle.link.peripheralIdentifier == identifier }
        if let listenCycle { return listenCycle.link.peripheralIdentifier == identifier }
        return identifier == record?.peripheralIdentifier || identifier == candidate?.identifier
            || identifier == listenCandidate?.identifier
    }

    /// Emits the pipeline's state, publishes its readings, then persists the session.
    private func apply(_ result: G7ReadingPipeline.Output) {
        if let state = result.state {
            if case .failed(let failure) = state { lastPipelineFailure = failure.kind } else { lastPipelineFailure = nil }
            emit(state)
        }
        result.readings.forEach(publish)
        syncSession()
    }

    /// D28: keep the persisted session (start, unconfirmed and latched end, newest reading) in step
    /// with the pipeline.
    private func syncSession() {
        guard let pipeline, var current = record, current.serial == pipeline.serial else { return }
        guard current.sessionStart != pipeline.sessionStart || current.sessionEnd != pipeline.sessionEnd
            || current.unconfirmedSessionEnd != pipeline.unconfirmedEnd
            || current.newestReading != pipeline.newestReading else { return }
        current.sessionStart = pipeline.sessionStart
        current.sessionEnd = pipeline.sessionEnd
        current.unconfirmedSessionEnd = pipeline.unconfirmedEnd
        current.newestReading = pipeline.newestReading
        saveRecord(current)
    }

    private func finishCycle() {
        if let listening = listenCycle {
            listening.finish()
            listenCycle = nil
            if let pipeline { apply(pipeline.endConnection()) }
            log(.ble, "listen: connection ended")
        }
        guard let ending = cycle else { return }
        ending.finish()
        cycle = nil
        if connectionAuthenticated, !connectionRejectedAfterAuthentication { rejectionAfterAuthenticationStreak = 0 }
        connectionAuthenticated = false
        connectionRejectedAfterAuthentication = false
        if let pipeline { apply(pipeline.endConnection()) }
        calibration.endConnection()
        log(.ble, "disconnected")
    }

    private func publish(_ reading: GlucoseReading) {
        output.reading(reading)
    }

    /// Connection-progress states are shown only until the sensor has reported its own state for
    /// this pairing; after that the ~5-minute reconnects would make the status line flicker.
    private func emitTransient(_ state: SensorState) {
        guard lastSensorState == nil else { return }
        emit(state)
    }

    private func emit(_ state: SensorState) {
        guard state != lastEmittedState else { return }
        lastEmittedState = state
        log(.sensor, "state \(state)")
        output.state(state)
    }

    /// The stored record if it belongs to the current mode. A record of the other mode is deleted
    /// (D45: switching modes leaves no orphaned key, code or session behind).
    private func loadRecordForMode() -> Result<G7PairingRecord?, Error> {
        switch loadRecord() {
        case .failure(let error):
            return .failure(error)
        case .success(let stored?) where stored.isListenRecord != isListening:
            do { try store.delete() } catch {
                log(.sensor, "could not delete the pairing record of the other mode: \(error)")
                return .failure(error)
            }
            log(.sensor, "stored \(stored.isListenRecord ? "listen-mode" : "primary-mode") pairing dropped: the mode is \(isListening ? "listen" : "primary")")
            return .success(nil)
        case .success(let stored):
            return .success(stored)
        }
    }

    private func loadRecord() -> Result<G7PairingRecord?, Error> {
        do { return .success(try store.load()) } catch {
            log(.sensor, "could not load the pairing record: \(error)")
            return .failure(error)
        }
    }

    /// The in-memory record keeps working until the app is terminated, but a relaunch would lose what
    /// was not saved (key, session start, session end): repeated failures are surfaced (S5).
    private func saveRecord(_ newRecord: G7PairingRecord) {
        record = newRecord
        do {
            try store.save(newRecord)
            consecutiveSaveFailures = 0
        } catch {
            consecutiveSaveFailures += 1
            log(.sensor, "could not save the pairing record (\(consecutiveSaveFailures) in a row): \(error)")
            if consecutiveSaveFailures >= Self.saveFailuresBeforeSurfacing {
                emit(.failed(G7FailureReason.credentialsUnavailable))
            }
        }
    }

    private func reportedParameters(_ record: G7PairingRecord) -> G7SensorLifetime.Parameters? {
        guard let length = record.reportedSessionLength, let warmUp = record.reportedWarmUp else { return nil }
        return G7SensorLifetime.parameters(reportedSessionLength: length, reportedWarmUp: warmUp)
    }

    private func log(_ category: DiagnosticEvent.Category, _ message: String) {
        diagnostics.record(DiagnosticEvent(date: now(), category: category, message: "G7: " + message))
    }
}
