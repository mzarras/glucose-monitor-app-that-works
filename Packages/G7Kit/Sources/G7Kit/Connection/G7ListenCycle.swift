// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/G7/CGMG7Transmitter.swift @ 7.1.0 (0370937)
// Changes: the coexistence (`useOtherApp`) observation of CGMG7Transmitter — design :51-66,
// characteristic subscription :714-717 and :1611-1622, value routing :744-750 and :994-1013,
// notify errors :755-783, authentication observation :1587-1609, the 0x31/0x25 join :1064-1102 —
// as a write-free connection cycle. Not ported, because each writes to the sensor during the
// Dexcom app's session: the queued calibration (:778-780, :1640-1734), the post-glucose `0x52`
// lifetime, `0x4A` firmware and `0x22` battery requests (:1104-1108 `sendPostGlucoseCommandIfReady`),
// and arming Backfill notifications (:1165-1174). See docs/g7-protocol.md §14 for each decision.

import Foundation

protocol G7ListenCycleDelegate: AnyObject {
    /// The `05` status the Dexcom app's own exchange produced says the link is authenticated and
    /// bonded. Only after this does the cycle forward anything from Write_Control (S2).
    func listenCycleObservedAuthentication()
    /// A `05` "not authenticated" followed the observed authentication: nothing more is forwarded
    /// from this connection.
    func listenCycleSawRejectionAfterAuthentication()
    /// A glucose report the Dexcom app's request produced (`0x4E`, or the `0x31`+`0x25` pair),
    /// with the receipt time of the frame that carries its session clock.
    func listenCycleReceivedGlucose(_ report: any G7GlucoseReport, receivedAt: Date)
    /// The Dexcom app asked the sensor for its session length and the answer was observed.
    func listenCycleReceivedExtendedVersion(_ message: G7ExtendedVersionMessage)
    func listenCycleLog(_ message: String)
}

/// One observed sensor connection in listen mode (D45): the Dexcom app on this phone owns it.
///
/// This cycle never writes to the sensor. It cannot: its link is a `G7ObservingLink`, which has no
/// write method. It subscribes to two characteristics, both of which the Dexcom app needs for its
/// own exchange, so its subscription is already on the shared link:
/// 1. Receive_Authentication, at once, to observe the `05` status the Dexcom app's authentication
///    produces (CGMG7Transmitter.swift:1611-1622). Auth_Stream is not subscribed: it carries
///    ownership payloads this app has no use for (:1615-1616).
/// 2. Write_Control, only after an authenticated and bonded `05` was observed (:1600-1602), so the
///    subscription never asks iOS to encrypt a link the Dexcom app has not secured yet.
/// Backfill is never subscribed: enabling it makes the sensor send its backfill now, which may
/// change what the Dexcom app receives (docs/g7-protocol.md §14).
final class G7ListenCycle {
    static let required: Set<G7Characteristic> = [.receiveAuthentication, .writeControl]

    weak var delegate: G7ListenCycleDelegate?
    let link: G7ObservingLink
    private let now: () -> Date
    /// The link is authenticated and bonded right now, as observed (S2 gate for every forward).
    private(set) var isObservedAuthenticated = false
    /// An authenticated status was observed at least once in this connection.
    private(set) var observedAuthenticationThisConnection = false
    private var rejected = false
    private(set) var isFinished = false
    private var pendingGlucose: G7CoexistenceGlucoseMessage?
    private var pendingClock: (message: G7TransmitterTimeMessage, receivedAt: Date)?

    init(link: G7ObservingLink, now: @escaping () -> Date) {
        self.link = link
        self.now = now
    }

    func start(availableCharacteristics: Set<G7Characteristic>) {
        let missing = Self.required.subtracting(availableCharacteristics)
        guard missing.isEmpty else {
            delegate?.listenCycleLog("listen: characteristics missing \(missing.map(\.rawValue).sorted()); nothing observed")
            return
        }
        link.setNotify(true, for: .receiveAuthentication)
    }

    /// The connection ended: nothing from it is forwarded any more.
    func finish() {
        isFinished = true
        isObservedAuthenticated = false
        pendingGlucose = nil
        pendingClock = nil
    }

    func notificationStateChanged(for characteristic: G7Characteristic, isNotifying: Bool, error: G7LinkError?) {
        guard !isFinished, let error else { return }
        // CGMG7Transmitter.swift:759-763: an encryption error means the Dexcom app has not secured
        // the link yet; this app never authenticates or bonds itself, so it only waits.
        delegate?.listenCycleLog("listen: notify \(characteristic) failed (\(error)); waiting for the Dexcom app")
    }

    func valueUpdated(for characteristic: G7Characteristic, value: Data) {
        guard !isFinished else { return }
        switch characteristic {
        case .receiveAuthentication:
            handleAuthentication(value)
        case .writeControl:
            guard isObservedAuthenticated else {
                delegate?.listenCycleLog("listen: Write_Control data without an observed authenticated status ignored")
                return
            }
            handleControl(value)
        case .authStream, .backfill, .communication:
            break // not subscribed; anything delivered anyway is not used
        }
    }

    // MARK: - Private

    /// CGMG7Transmitter.swift:1587-1609. Only `05` matters; `02`/`03`/`04`/`0A`… are the Dexcom app's
    /// own exchange and carry nothing this app may use.
    private func handleAuthentication(_ value: Data) {
        guard value.first == G7Opcode.authStatus.rawValue, let status = G7AuthStatusMessage(value) else { return }
        if status.authenticated, status.paired {
            guard !isObservedAuthenticated, !rejected else { return }
            isObservedAuthenticated = true
            observedAuthenticationThisConnection = true
            delegate?.listenCycleObservedAuthentication()
            if !link.isNotifying(.writeControl) { link.setNotify(true, for: .writeControl) }
        } else if isObservedAuthenticated {
            // As in primary mode (safety review N2): stop forwarding at once; nothing re-enables it
            // in this connection.
            isObservedAuthenticated = false
            rejected = true
            pendingGlucose = nil
            pendingClock = nil
            delegate?.listenCycleSawRejectionAfterAuthentication()
        } else {
            delegate?.listenCycleLog("listen: authentication status \(value.hexString) observed; not (yet) authenticated and bonded")
        }
    }

    /// CGMG7Transmitter.swift:994-1013, for the frames listen mode uses.
    private func handleControl(_ value: Data) {
        switch value.first.flatMap(G7Opcode.init(rawValue:)) {
        case .glucose?:
            guard let message = G7GlucoseMessage(value) else {
                delegate?.listenCycleLog("listen: malformed 0x4E \(value.hexString)")
                return
            }
            delegate?.listenCycleReceivedGlucose(message, receivedAt: now())
        case .coexistenceGlucose?:
            guard let message = G7CoexistenceGlucoseMessage(value) else {
                delegate?.listenCycleLog("listen: 0x31 with a bad length or CRC dropped \(value.hexString)")
                return
            }
            pendingGlucose = message
            joinIfReady()
        case .transmitterTime?:
            guard let message = G7TransmitterTimeMessage(value) else {
                delegate?.listenCycleLog("listen: 0x25 with a bad length or CRC dropped \(value.hexString)")
                return
            }
            pendingClock = (message, now())
            joinIfReady()
        case .extendedVersion?:
            if let message = G7ExtendedVersionMessage(value) {
                delegate?.listenCycleReceivedExtendedVersion(message)
            } else {
                delegate?.listenCycleLog("listen: malformed 0x52 \(value.hexString)")
            }
        default:
            // Recorded by opcode and length only, so the Dexcom app's traffic can be understood later.
            let opcode = value.first.map { String(format: "%02X", $0) } ?? "--"
            delegate?.listenCycleLog("listen: Write_Control 0x\(opcode) (\(value.count) bytes) observed; not used")
        }
    }

    /// CGMG7Transmitter.swift:1064-1102: either half may come first; a pair is used once.
    private func joinIfReady() {
        guard let glucose = pendingGlucose, let clock = pendingClock else { return }
        pendingGlucose = nil
        pendingClock = nil
        guard let pair = G7ObservedGlucosePair(glucose: glucose, clock: clock.message) else {
            delegate?.listenCycleLog("listen: 0x25 reports no running session; 0x31 not used")
            return
        }
        delegate?.listenCycleReceivedGlucose(pair, receivedAt: clock.receivedAt)
    }
}
