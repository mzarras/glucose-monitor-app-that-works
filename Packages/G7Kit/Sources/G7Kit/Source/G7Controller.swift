// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the primary-mode connection policy of CGMG7Transmitter (connect :429-444, didDiscover
// :553-593, reconnectAfterDisconnect :595-603, didConnect :605-654, didDisconnectPeripheral
// :656-688, authSessionDidRejectPersistedKey :969-979, authSessionRequiresCleanReconnect
// :981-989) and BluetoothTransmitter's pending-connect reconnect (BluetoothTransmitter.swift:313-317),
// with pairing state in G7CredentialStore instead of Core Data/UserDefaults.

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
}

/// Everything G7 primary mode decides across connections: pairing, reconnection, the reading
/// pipeline, the persisted session, calibration and state. Not thread-safe: `G7CGMSource` calls
/// every method on its one serial queue (the CoreBluetooth delegate queue).
final class G7Controller: G7ConnectionCycleDelegate {
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

    private let store: G7CredentialStore
    private let diagnostics: DiagnosticLog
    private let now: () -> Date
    private let slot: G7AuthenticationSlot
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
    /// During a new pairing: the previous sensor and any sensor that rejected the code or timed out.
    private var excludedSensorNames: Set<String> = []
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

    init(
        store: G7CredentialStore,
        diagnostics: DiagnosticLog,
        now: @escaping () -> Date,
        slot: G7AuthenticationSlot,
        output: Output,
        makeAuthSession: @escaping (G7Link, G7PairingRecord) -> G7AuthSession = { link, record in
            G7AuthSession(link: link, slot: record.slot, pairingCode: record.pairingCode, savedKey: record.sharedKey.map { [UInt8]($0) })
        }
    ) {
        self.store = store
        self.diagnostics = diagnostics
        self.now = now
        self.slot = slot
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
        switch loadRecord() {
        case .failure:
            emit(.failed(G7FailureReason.credentialsUnavailable))
        case .success(nil):
            emit(.notPaired)
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

    /// Only for a sensor this app has authenticated to (serial fixed) and still may use.
    var heartbeatTarget: G7HeartbeatTarget? {
        guard let record, record.serial != nil, !record.requiresNewPairing,
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
            excludedSensorNames = previousIsFinished ? Set([previous?.sensorName].compactMap { $0 }) : []
            log(.sensor, "pairing a new sensor in slot \(slot.rawValue)")
        } else {
            switch loadRecord() {
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
        guard G7PairingCode.isValid(pairingCode) else { throw .invalidPairingCode }
        let stored: G7PairingRecord?
        switch loadRecord() {
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
        excludedSensorNames = []
        log(.sensor, "pairing \(updated.sensorName ?? "the sensor") again in slot \(updated.slot.rawValue)")
        resume()
    }

    /// A new or repeated pairing starts without the previous connections' history.
    private func resetConnectionHistory() {
        rejectionAfterAuthenticationStreak = 0
        lastPipelineFailure = nil
        candidate = nil
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
        central?.stopScanning()
        if let identifier = cycle?.link.peripheralIdentifier ?? record?.peripheralIdentifier {
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
        excludedSensorNames = []
        log(.sensor, "sensor forgotten")
        emit(.notPaired)
    }

    // MARK: - Calibration

    func submitCalibration(_ request: CalibrationRequest) throws(CalibrationRefusal) {
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
        if let lastSensorState {
            emit(lastSensorState)
        } else if record == nil {
            emit(.notPaired)
        }
        connectIfPossible()
    }

    func didDiscover(name: String?, identifier: UUID) {
        guard isRunning, cycle == nil, let record, !record.requiresNewPairing, let name else { return }
        if let knownName = record.sensorName {
            // Reconnecting a paired sensor that iOS could not retrieve by identifier.
            guard name == knownName else { return }
        } else {
            // New pairing: any G7 10-day sensor except the old one and ones that refused the code.
            guard name.hasPrefix(G7GATT.sensorNamePrefix), !excludedSensorNames.contains(name) else { return }
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

    func notificationStateChanged(for characteristic: G7Characteristic, isNotifying: Bool, error: G7LinkError?) {
        cycle?.notificationStateChanged(for: characteristic, isNotifying: isNotifying, error: error)
    }

    func valueUpdated(for characteristic: G7Characteristic, value: Data) {
        cycle?.valueUpdated(for: characteristic, value: value)
    }

    func writeFailed(for characteristic: G7Characteristic, error: G7LinkError) {
        cycle?.writeFailed(for: characteristic, error: error)
    }

    /// The sensor disconnected (normal after each ~5-minute exchange) or the link dropped.
    func didDisconnect(peripheralIdentifier: UUID) {
        guard isExpected(peripheralIdentifier) else {
            log(.ble, "disconnect of an unrelated peripheral ignored")
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
            excludedSensorNames = []
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
                excludedSensorNames.insert(candidate.name)
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
        guard let pipeline else { return }
        let result = pipeline.handleGlucose(message, receivedAt: now())
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

    // MARK: - Private

    private func connectIfPossible() {
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
        if record?.sensorName == nil { excludedSensorNames.insert(timedOut.name) }
        central?.cancelConnection(peripheralIdentifier: timedOut.identifier)
        log(.ble, "\(timedOut.name) did not connect within \(Int(Self.candidateConnectTimeout)) s; scanning again")
        guard isRunning else { return }
        connectIfPossible()
    }

    /// Events about peripherals other than the paired sensor or the current candidate are ignored.
    private func isExpected(_ identifier: UUID) -> Bool {
        if let cycle { return cycle.link.peripheralIdentifier == identifier }
        return identifier == record?.peripheralIdentifier || identifier == candidate?.identifier
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
