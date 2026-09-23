// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the primary-mode routing of CGMG7Transmitter (didDiscoverCharacteristicsFor :690-725,
// didUpdateValueFor :727-753, didUpdateNotificationStateFor :755-785, didWriteValueFor :787-845,
// authSessionDidAuthenticate :952-967, handleWriteControlValue :995-1016,
// sendPrimaryGlucoseRequestIfReady :1624-1642) over `G7Link`. Coexistence, battery and firmware
// requests are not ported. Control requests are sequenced one at a time here; the caller decides
// which (calibration, calibration record, extended version).

import Foundation

protocol G7ConnectionCycleDelegate: AnyObject {
    func cycleDidAuthenticate(newlyConfirmedKey: [UInt8]?)
    func cycleSavedKeyRejected()
    func cycleNeedsFullBootstrap()
    func cycleAuthFailed(_ failure: G7AuthFailure)
    /// A `05` rejection arrived after this connection authenticated (see G7AuthSessionDelegate).
    func cycleSawRejectionAfterAuthentication()
    /// True while the sensor has not yet reported its session length: `52` is then requested before
    /// GetData, so no reading is ever handled without sensor-reported session timing.
    func cycleNeedsSessionLength() -> Bool
    /// A notify/write failed in a way that means the iOS Bluetooth pairing is not in place.
    func cycleLinkFailed(_ error: G7LinkError)
    func cycleReceivedGlucose(_ message: G7GlucoseMessage)
    func cycleReceivedBackfillFrame(_ frame: Data)
    func cycleBackfillFinished()
    func cycleReceivedExtendedVersion(_ message: G7ExtendedVersionMessage)
    func cycleReceivedCalibrationResponse(_ response: G7CalibrationCommandResponse)
    func cycleReceivedCalibrationRecord(_ record: G7CalibrationBounds)
    /// The next one-byte or calibration request to write to Write_Control, or nil when done.
    func cycleNextControlRequest() -> Data?
    func cycleControlWriteFailed(_ request: Data)
    func cycleLog(_ message: String)
}

/// One BLE connection to the sensor (the G7 connects for a few seconds about every 5 minutes).
///
/// Order within a connection:
/// 1. notify Auth_Stream, then Receive_Authentication; authenticate (G7AuthSession);
/// 2. notify Write_Control; if the session length is still unknown write `52` and wait for its
///    answer (Sensor change: xDrip4iOS asks after the first reading, CGMG7Transmitter.swift:1361-1389,
///    which would let a 15-day sensor publish one reading); then write `4E` (GetData) once
///    (CGMG7Transmitter.swift:1624-1642);
/// 3. on the `0x4E` response: notify Backfill (CGMG7Transmitter.swift:1165-1174), then write the
///    caller's control requests one at a time, each after the previous response;
/// 4. backfill records arrive on Backfill, `59` on Write_Control ends them.
/// Nothing from Write_Control or Backfill is forwarded before authentication completes, nor after a
/// `05` rejection ends it (S2).
final class G7ConnectionCycle: G7AuthSessionDelegate {
    weak var delegate: G7ConnectionCycleDelegate?
    let link: G7Link
    private let auth: G7AuthSession
    private var glucoseRequestSent = false
    private var extendedVersionRequested = false
    private var awaitingControlResponse: Data?
    private(set) var isFinished = false

    init(link: G7Link, auth: G7AuthSession) {
        self.link = link
        self.auth = auth
        auth.delegate = self
    }

    var isAuthenticated: Bool { auth.isAuthenticated }

    /// `52` was written and not answered: the session length is still unknown.
    var isAwaitingSessionLength: Bool { awaitingControlResponse == G7ControlRequest.extendedVersion }

    /// Call once the characteristics are discovered.
    func start(availableCharacteristics: Set<G7Characteristic>) {
        let missing = G7Characteristic.required.subtracting(availableCharacteristics)
        guard missing.isEmpty else {
            delegate?.cycleLog("connection: characteristics missing \(missing.map(\.rawValue).sorted())")
            delegate?.cycleAuthFailed(.protocolError("required characteristics missing"))
            return
        }
        auth.begin()
    }

    /// The connection ended; nothing scheduled from it may run any more.
    func finish() {
        isFinished = true
        auth.cancel()
    }

    func notificationStateChanged(for characteristic: G7Characteristic, isNotifying: Bool, error: G7LinkError?) {
        guard !isFinished else { return }
        if let error {
            delegate?.cycleLog("connection: notify \(characteristic) failed: \(error)")
            handleLinkError(error)
            return
        }
        switch characteristic {
        case .authStream, .receiveAuthentication:
            auth.notificationStateChanged(for: characteristic, isNotifying: isNotifying)
        case .writeControl:
            if isNotifying { sendGlucoseRequestIfReady() }
        case .backfill, .communication:
            break
        }
    }

    func valueUpdated(for characteristic: G7Characteristic, value: Data) {
        guard !isFinished else { return }
        switch characteristic {
        case .receiveAuthentication:
            auth.receiveAuthentication(value)
        case .authStream:
            auth.receiveAuthStream(value)
        case .writeControl:
            guard auth.isAuthenticated else {
                delegate?.cycleLog("connection: Write_Control data before authentication ignored")
                return
            }
            handleWriteControl(value)
        case .backfill:
            guard auth.isAuthenticated else {
                delegate?.cycleLog("connection: backfill before authentication ignored")
                return
            }
            delegate?.cycleReceivedBackfillFrame(value)
        case .communication:
            break
        }
    }

    func writeFailed(for characteristic: G7Characteristic, error: G7LinkError) {
        guard !isFinished else { return }
        delegate?.cycleLog("connection: write to \(characteristic) failed: \(error)")
        if case .other = error, characteristic == .writeControl, let request = awaitingControlResponse {
            awaitingControlResponse = nil
            delegate?.cycleControlWriteFailed(request)
            // Without `52` the readings are withheld (G7ReadingPipeline), but GetData still reports state.
            if request == G7ControlRequest.extendedVersion { sendGlucoseRequestIfReady() }
            return
        }
        handleLinkError(error)
    }

    // MARK: - G7AuthSessionDelegate

    func authSessionDidAuthenticate(newlyConfirmedKey: [UInt8]?) {
        delegate?.cycleDidAuthenticate(newlyConfirmedKey: newlyConfirmedKey)
        // Arm Write_Control; GetData follows once it notifies (CGMG7Transmitter.swift:952-967).
        if link.isNotifying(.writeControl) {
            sendGlucoseRequestIfReady()
        } else {
            link.setNotify(true, for: .writeControl)
        }
    }

    func authSessionDidRejectSavedKey() { delegate?.cycleSavedKeyRejected() }
    func authSessionNeedsFullBootstrap() { delegate?.cycleNeedsFullBootstrap() }
    func authSessionDidFail(_ failure: G7AuthFailure) { delegate?.cycleAuthFailed(failure) }
    /// The auth session has already left `.authenticated`, so Write_Control and Backfill data are no
    /// longer forwarded; the delegate finishes this cycle before asking for the disconnect.
    func authSessionSawRejectionAfterAuthentication() { delegate?.cycleSawRejectionAfterAuthentication() }
    func authSessionLog(_ message: String) { delegate?.cycleLog(message) }

    // MARK: - Private

    private func handleLinkError(_ error: G7LinkError) {
        switch error {
        case .pairingNotCompleted, .bondRemovedBySensor:
            delegate?.cycleLinkFailed(error)
        case .other:
            break
        }
    }

    /// One GetData per connection (CGMG7Transmitter.swift:1631-1641), preceded by `52` while the
    /// session length is unknown.
    private func sendGlucoseRequestIfReady() {
        guard auth.isAuthenticated, !glucoseRequestSent, link.isNotifying(.writeControl), awaitingControlResponse == nil else { return }
        if !extendedVersionRequested, delegate?.cycleNeedsSessionLength() == true {
            extendedVersionRequested = true
            awaitingControlResponse = G7ControlRequest.extendedVersion
            if link.write(G7ControlRequest.extendedVersion, to: .writeControl, withResponse: true) { return }
            awaitingControlResponse = nil
        }
        glucoseRequestSent = true
        if !link.write(G7ControlRequest.glucose, to: .writeControl, withResponse: true) {
            glucoseRequestSent = false
        }
    }

    /// Routes by opcode (CGMG7Transmitter.swift:995-1016).
    private func handleWriteControl(_ value: Data) {
        guard let first = value.first, let opcode = G7Opcode(rawValue: first) else {
            delegate?.cycleLog("connection: unknown Write_Control data \(value.hexString)")
            return
        }
        switch opcode {
        case .glucose:
            guard let message = G7GlucoseMessage(value) else {
                delegate?.cycleLog("connection: malformed 0x4E \(value.hexString)")
                return
            }
            delegate?.cycleReceivedGlucose(message)
            if !link.isNotifying(.backfill) { link.setNotify(true, for: .backfill) }
            sendNextControlRequest()
        case .extendedVersion:
            awaitingControlResponse = nil
            if let message = G7ExtendedVersionMessage(value) {
                delegate?.cycleReceivedExtendedVersion(message)
            } else {
                delegate?.cycleLog("connection: malformed 0x52 \(value.hexString)")
            }
            if glucoseRequestSent { sendNextControlRequest() } else { sendGlucoseRequestIfReady() }
        case .calibrate:
            awaitingControlResponse = nil
            if let response = G7CalibrationCommandResponse(value) {
                delegate?.cycleReceivedCalibrationResponse(response)
            } else {
                delegate?.cycleLog("connection: malformed 0x34 response \(value.hexString)")
            }
            sendNextControlRequest()
        case .calibrationBounds:
            awaitingControlResponse = nil
            if let record = G7CalibrationBounds(value) {
                delegate?.cycleReceivedCalibrationRecord(record)
            } else {
                delegate?.cycleLog("connection: malformed 0x32 record \(value.hexString)")
            }
            sendNextControlRequest()
        case .backfillFinished:
            delegate?.cycleBackfillFinished()
        default:
            delegate?.cycleLog("connection: Write_Control \(value.hexString) not used")
        }
    }

    private func sendNextControlRequest() {
        guard awaitingControlResponse == nil, let request = delegate?.cycleNextControlRequest() else { return }
        awaitingControlResponse = request
        if !link.write(request, to: .writeControl, withResponse: true) {
            awaitingControlResponse = nil
            delegate?.cycleControlWriteFailed(request)
        }
    }
}
