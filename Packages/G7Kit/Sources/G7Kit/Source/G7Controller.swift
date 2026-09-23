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
    /// The credential store failed; nothing was started.
    case credentialStoreFailed(String)
}

/// Everything G7 primary mode decides across connections: pairing, reconnection, the reading
/// pipeline, calibration and state. Not thread-safe: `G7CGMSource` calls every method on its one
/// serial queue (the CoreBluetooth delegate queue).
final class G7Controller: G7ConnectionCycleDelegate {
    struct Output {
        let reading: (GlucoseReading) -> Void
        let state: (SensorState) -> Void
        let calibration: (CalibrationUpdate) -> Void
    }

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
    /// During a new pairing: the previous sensor and any sensor that rejected the code.
    private var excludedSensorNames: Set<String> = []
    /// During a new pairing: the advertised sensor currently being tried.
    private var candidate: (name: String, identifier: UUID)?
    private var extendedVersionRequestedThisConnection = false

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
    func emitInitialState() {
        guard let stored = loadRecord() else {
            emit(.notPaired)
            return
        }
        emit(stored.requiresNewPairing ? .failed(reason: G7FailureReason.savedKeyRejected) : .searching)
    }

    var currentSession: SensorSession? {
        guard let pipeline, !pipeline.isUnsupportedSensor, record?.requiresNewPairing == false else { return nil }
        return pipeline.session
    }

    /// Only for a sensor this app has authenticated to (serial fixed) and still may use.
    var heartbeatTarget: G7HeartbeatTarget? {
        guard let record, record.serial != nil, !record.requiresNewPairing,
              let identifier = record.peripheralIdentifier else { return nil }
        return G7HeartbeatTarget(peripheralIdentifier: identifier)
    }

    // MARK: - Lifecycle

    /// Pairs a new sensor when `pairingCode` is given, otherwise resumes the stored pairing.
    func start(pairingCode: String?) throws(G7StartError) {
        if let pairingCode {
            guard G7PairingCode.isValid(pairingCode) else { throw .invalidPairingCode }
            let previous = loadRecord()
            if let identifier = previous?.peripheralIdentifier { central?.cancelConnection(peripheralIdentifier: identifier) }
            finishCycle()
            calibration.cancelAll(reason: "A new sensor is being paired")
            var newRecord = G7PairingRecord(pairingCode: pairingCode, slot: slot)
            newRecord.requiresNewPairing = false
            do { try store.save(newRecord) } catch { throw .credentialStoreFailed("\(error)") }
            record = newRecord
            pipeline = nil
            lastSensorState = nil
            excludedSensorNames = Set([previous?.sensorName].compactMap { $0 })
            candidate = nil
            log(.sensor, "pairing a new sensor in slot \(slot.rawValue)")
        } else {
            do { record = try store.load() } catch { throw .credentialStoreFailed("\(error)") }
        }
        isRunning = true
        guard let record else {
            emit(.notPaired)
            return
        }
        if record.requiresNewPairing {
            emit(.failed(reason: G7FailureReason.savedKeyRejected))
            return
        }
        if let power = G7SensorStatus.state(for: bluetoothPower) {
            emit(power)
            return
        }
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
        candidate = nil
        excludedSensorNames = []
        log(.sensor, "sensor forgotten")
        emit(.notPaired)
    }

    // MARK: - Calibration

    func submitCalibration(_ request: CalibrationRequest) throws(CalibrationRefusal) {
        let context = G7CalibrationQueue.Context(
            isPaired: record != nil,
            isAuthenticated: record?.sharedKey != nil && record?.requiresNewPairing == false && pipeline?.isUnsupportedSensor == false,
            sensorState: lastSensorState
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
            candidate = (name, identifier)
        }
        log(.ble, "found \(name); connecting")
        central?.stopScanning()
        _ = central?.connect(peripheralIdentifier: identifier)
    }

    /// The link is connected and its characteristics are discovered.
    func didConnect(link: G7Link, availableCharacteristics: Set<G7Characteristic>) {
        guard isRunning, let record, !record.requiresNewPairing else {
            link.disconnect()
            return
        }
        finishCycle()
        log(.ble, "connected")
        emitTransient(.authenticating)
        pipeline?.beginConnection()
        calibration.beginConnection()
        extendedVersionRequestedThisConnection = false
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
        finishCycle()
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
            candidate = nil
            log(.sensor, "paired with \(name), serial \(current.serial ?? "?")")
        }
        // A paired sensor found again by name can come back under a new iOS identifier; reconnect to
        // that one from now on. The serial never changes (reading ids stay stable).
        current.peripheralIdentifier = link.peripheralIdentifier
        if let key = newlyConfirmedKey {
            current.sharedKey = Data(key)
            log(.sensor, "ownership confirmed; key saved for short authentication")
        }
        saveRecord(current)
        if let serial = current.serial, pipeline?.serial != serial {
            pipeline = G7ReadingPipeline(serial: serial, reportedParameters: reportedParameters(current)) { [weak self] message in
                self?.log(.sensor, message)
            }
            pipeline?.beginConnection()
        }
        log(.ble, "authenticated")
    }

    func cycleSavedKeyRejected() {
        guard var current = record else { return }
        current.requiresNewPairing = true
        saveRecord(current)
        log(.sensor, "saved key rejected; automatic reconnection stopped")
        emit(.failed(reason: G7FailureReason.savedKeyRejected))
        cycle?.link.disconnect()
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
            emit(.failed(reason: G7FailureReason.pairingCodeRejected))
        case .missingPairingCode:
            emit(.failed(reason: G7FailureReason.pairingCodeNeeded))
        case .pakeRejectedBySensor, .pake, .certificateExchangeRejected, .proofRejected, .protocolError:
            emit(.failed(reason: G7FailureReason.authenticationFailed))
        }
        cycle?.link.disconnect()
    }

    func cycleLinkFailed(_ error: G7LinkError) {
        switch error {
        case .pairingNotCompleted:
            emit(.failed(reason: G7FailureReason.bluetoothPairingNotCompleted))
        case .bondRemovedBySensor:
            emit(.failed(reason: G7FailureReason.bondRemovedBySensor))
        case .other:
            return
        }
        cycle?.link.disconnect()
    }

    func cycleReceivedGlucose(_ message: G7GlucoseMessage) {
        guard let pipeline else { return }
        let result = pipeline.handleGlucose(message, receivedAt: now())
        if let state = result.state {
            lastSensorState = state
            emit(state)
        }
        result.readings.forEach(publish)
    }

    func cycleReceivedBackfillFrame(_ frame: Data) {
        pipeline?.handleBackfillFrame(frame, now: now())
    }

    func cycleBackfillFinished() {
        pipeline?.flushBackfill().forEach(publish)
    }

    func cycleReceivedExtendedVersion(_ message: G7ExtendedVersionMessage) {
        guard let pipeline, var current = record else { return }
        let result = pipeline.handleExtendedVersion(message)
        log(.sensor, "session length \(message.sessionLength) s, warm-up \(message.warmUpDuration) s")
        if let state = result.state {
            lastSensorState = state
            emit(state)
        }
        if !pipeline.isUnsupportedSensor {
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

    /// Priority as xDrip4iOS: calibration work first, then the unknown lifetime
    /// (CGMG7Transmitter.swift:1237-1248). Battery/firmware requests are not ported.
    func cycleNextControlRequest() -> Data? {
        guard let pipeline, let clock = pipeline.clock, !pipeline.isUnsupportedSensor else { return nil }
        if let command = calibration.nextCommand(clock: clock, now: now()) { return command }
        if record?.reportedSessionLength == nil, !extendedVersionRequestedThisConnection {
            extendedVersionRequestedThisConnection = true
            return G7ControlRequest.extendedVersion
        }
        return nil
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

    private func finishCycle() {
        guard let ending = cycle else { return }
        ending.finish()
        cycle = nil
        pipeline?.endConnection().forEach(publish)
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

    private func loadRecord() -> G7PairingRecord? {
        do { return try store.load() } catch {
            log(.sensor, "could not load the pairing record: \(error)")
            return nil
        }
    }

    private func saveRecord(_ newRecord: G7PairingRecord) {
        record = newRecord
        do { try store.save(newRecord) } catch {
            // The in-memory record still works until the app is terminated; make the failure visible.
            log(.sensor, "could not save the pairing record: \(error)")
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
