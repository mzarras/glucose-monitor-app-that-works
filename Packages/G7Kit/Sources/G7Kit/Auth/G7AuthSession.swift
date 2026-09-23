// Originally part of xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
// The original file carries no copyright header of its own.
// Ported from xDrip4iOS xDrip/BluetoothTransmitter/CGM/Dexcom/Generic/DexcomG7AuthSession.swift @ 7.1.0 (0370937)
// Changes: talks to `G7Link` instead of CBCharacteristic; the crypto calls go to the Swift ports
// (G7JPAKEClient, G7ChallengeHash, G7OwnershipCredentials) instead of DexcomG7AuthBridge; the key
// is supplied by and reported to the caller instead of being persisted in UserDefaults; failures
// are reported to the delegate (xDrip4iOS only traced them) so they can surface in the UI (S5).

import Foundation

protocol G7AuthSessionDelegate: AnyObject {
    /// Primary data access is granted. `newlyConfirmedKey` is non-nil only after a full J-PAKE
    /// ownership exchange; the caller must persist it for short authentication next time.
    func authSessionDidAuthenticate(newlyConfirmedKey: [UInt8]?)
    /// The saved key was refused: another collector probably owns this slot now. Do not retry.
    func authSessionDidRejectSavedKey()
    /// Authenticated but not paired: drop the saved key and reconnect for a full bootstrap.
    func authSessionNeedsFullBootstrap()
    func authSessionDidFail(_ failure: G7AuthFailure)
    /// After we authenticated, a `05` saying "not authenticated" arrived. It may be the sensor
    /// revoking our key, or another app on the shared link failing; either way stop this connection
    /// and let the next connection's own (solicited) status decide.
    func authSessionSawRejectionAfterAuthentication()
    func authSessionLog(_ message: String)
}

/// Why authentication stopped. None of these is retried inside the same connection.
enum G7AuthFailure: Equatable, Sendable {
    case missingPairingCode
    /// Full bootstrap finished J-PAKE but the sensor answered "not authenticated": the derived key
    /// does not match, i.e. the pairing code is wrong for this sensor (DexcomG7AuthSession.swift:436-441).
    case pairingCodeRejected
    case pakeRejectedBySensor
    case pake(G7JPAKEClient.Failure)
    case certificateExchangeRejected
    case proofRejected
    case protocolError(String)
}

/// The G7 primary authentication and ownership state machine for one connection.
///
/// Short path (a confirmed key exists): `02 token slot` → `03 hash challenge` → `04 hash` →
/// `05 01 01` → authenticated.
/// Full path (new sensor or slot): `0A 00` → three J-PAKE phases → `02 …` → `03` → `04` → `05 01 xx`
/// → certificate phases 0-2 → proof of possession → `0D` → `06 19` → `06 01` (or legacy `07`/`08 01`)
/// → key confirmed → authenticated. Details: docs/g7-protocol.md "Authentication".
///
/// Only solicited packets count (Sensor change, safety review B1). iOS shares one Bluetooth link
/// per peripheral between apps and delivers every notification to every subscribed app, so another
/// G7 app's traffic reaches us too. xDrip4iOS accepted any `05` (DexcomG7AuthSession.swift:262,
/// :396-458); here a `03` counts only after our own `02`, a `05` only after our own `04` and only
/// once, and the ownership opcodes only in their own stage. Anything else is logged and ignored.
final class G7AuthSession {
    enum StatusAction: Equatable {
        case continueAuthentication
        case rejectSavedKey
        case startFullBootstrap
        case reject
    }

    private enum Stage: String {
        case idle, authenticating, certificateExchange, proofOfPossession, keepAlive, bondRequest
        case pairConfirmation, authenticated, failed
    }

    /// Auth_Stream fragments are 20 bytes (DexcomG7AuthBridge.m:1012-1025, DexcomG7AuthSession.swift:619).
    static let streamFragmentLength = 20
    /// Spacing between writes without response (DexcomG7AuthSession.swift:643).
    static let streamPacketSpacing: TimeInterval = 0.04
    /// Remote certificate sizes above this are refused before buffering (DexcomG7AuthSession.swift:549-559).
    static let maximumCertificateSize = 4096
    /// The sensor's proof on Auth_Stream is 64 bytes (DexcomG7AuthSession.swift:607-614).
    static let remoteProofLength = 64

    weak var delegate: G7AuthSessionDelegate?
    private let link: G7Link
    private let slot: G7AuthenticationSlot
    private let pairingCode: String?
    private let savedKey: [UInt8]?
    private let randomBytes: (Int) -> [UInt8]
    private let makeJPAKE: (String) throws(G7JPAKEClient.Failure) -> G7JPAKEClient

    private var stage: Stage = .idle
    private var authStreamBuffer: [UInt8] = []
    private var authStreamReady = false
    private var receiveAuthenticationReady = false
    private var initialControlPacketSent = false
    private var challengeResponseSent = false
    /// The one `05` answering our `04` has been handled.
    private var statusAnswered = false
    /// The J-PAKE phase whose `0A 00 <phase>` we are waiting for.
    private var expectedPakePhase: UInt8 = 0
    private var proofChallengeRequested = false
    private var usingFullBootstrap = false
    private var certificateExchangeStarted = false
    private var pendingPakePhase: UInt8?
    private var pendingCertificatePhase: UInt8?
    private var pendingCertificateSize: Int?
    private var expectedCertificatePhase: UInt8 = 0
    private var pendingProofChallenge: [UInt8]?
    private var jpake: G7JPAKEClient?
    private var candidateKey: [UInt8]?
    private var lastToken: [UInt8]?
    /// Delayed writes check this so nothing from an ended session reaches a new one
    /// (DexcomG7AuthSession.swift:124-127).
    private var writeGeneration = 0

    var isAuthenticated: Bool { stage == .authenticated }

    init(
        link: G7Link,
        slot: G7AuthenticationSlot,
        pairingCode: String?,
        savedKey: [UInt8]?,
        randomBytes: @escaping (Int) -> [UInt8] = G7Random.bytes,
        makeJPAKE: @escaping (String) throws(G7JPAKEClient.Failure) -> G7JPAKEClient = { code throws(G7JPAKEClient.Failure) in
            try G7JPAKEClient(pairingCode: code)
        }
    ) {
        self.link = link
        self.slot = slot
        self.pairingCode = pairingCode
        self.savedKey = savedKey?.count == 16 ? savedKey : nil
        self.randomBytes = randomBytes
        self.makeJPAKE = makeJPAKE
    }

    /// Enables Auth_Stream first, then Receive_Authentication: the sensor can announce a J-PAKE
    /// phase and send its 160-byte payload immediately, so the stream must already be listening
    /// (DexcomG7AuthSession.swift:192-211).
    func begin() {
        if link.isNotifying(.authStream) {
            authStreamReady = true
            subscribeToReceiveAuthentication()
        } else {
            link.setNotify(true, for: .authStream)
        }
    }

    /// Invalidates delayed writes (connection ended).
    func cancel() {
        writeGeneration &+= 1
        stage = .idle
    }

    func notificationStateChanged(for characteristic: G7Characteristic, isNotifying: Bool) {
        switch characteristic {
        case .authStream:
            authStreamReady = isNotifying
            if isNotifying { subscribeToReceiveAuthentication() }
        case .receiveAuthentication:
            receiveAuthenticationReady = isNotifying
            if isNotifying { startAuthenticationIfReady() }
        default:
            break
        }
    }

    /// Auth_Stream notification boundaries are not message boundaries; buffer everything and let
    /// the pending phase consume its documented byte count (DexcomG7AuthSession.swift:230-241).
    func receiveAuthStream(_ value: Data) {
        guard stage != .idle, stage != .failed else { return }
        authStreamBuffer += value
        processPendingPakeIfReady()
        processPendingCertificateIfReady()
        processPendingProofIfReady()
    }

    func receiveAuthentication(_ value: Data) {
        guard stage != .failed, let first = value.first, let opcode = G7Opcode(rawValue: first) else {
            if stage != .failed { delegate?.authSessionLog("auth: unknown packet \(value.hexString)") }
            return
        }
        switch opcode {
        case .authChallenge:
            handleChallenge(value)
        case .authStatus:
            handleStatus(value)
        case .pakeExchange:
            // Only while our own J-PAKE is running and before our `02` (DexcomG7AuthSession.swift:264-272).
            guard stage == .authenticating, usingFullBootstrap, lastToken == nil, pendingPakePhase == nil else {
                ignoreUnsolicited(value)
                return
            }
            guard let status = G7PakeStatus(value) else {
                fail(.pakeRejectedBySensor, packet: value)
                return
            }
            guard status.phase == expectedPakePhase else {
                ignoreUnsolicited(value)
                return
            }
            pendingPakePhase = status.phase
            processPendingPakeIfReady()
        case .certificateExchange:
            guard stage == .certificateExchange else {
                ignoreUnsolicited(value)
                return
            }
            handleCertificateStatus(value)
        case .proofOfPossession:
            guard stage == .certificateExchange, proofChallengeRequested else {
                ignoreUnsolicited(value)
                return
            }
            handleProofChallenge(value)
        case .authProofStatus:
            // The sensor accepted our signature; close ownership with the 25 s keep-alive
            // (DexcomG7AuthSession.swift:284-292).
            guard stage == .proofOfPossession else { return }
            stage = .keepAlive
            writeControl(G7OwnershipKeepAlive.request)
        case .keepAlive:
            guard stage == .keepAlive else { return }
            switch G7OwnershipKeepAlive.outcome(of: value) {
            case .complete:
                completeOwnership(via: "06 01")
            case .legacyBondRequired:
                stage = .bondRequest
                writeControl(G7LegacyBond.request)
            case .ignore:
                return
            }
        case .bondRequest:
            guard stage == .bondRequest, G7LegacyBond.isBondRequestEcho(value) else { return }
            stage = .pairConfirmation
        case .pairConfirmation:
            guard stage == .pairConfirmation, G7LegacyBond.isPairConfirmation(value) else { return }
            completeOwnership(via: "08 01")
        default:
            break
        }
    }

    /// DexcomG7AuthSession.swift:463-475 (`authenticationStatusAction`), unchanged.
    static func statusAction(usingFullBootstrap: Bool, authenticated: Bool, paired: Bool) -> StatusAction {
        if usingFullBootstrap {
            return authenticated ? .continueAuthentication : .reject
        }
        if authenticated {
            return paired ? .continueAuthentication : .startFullBootstrap
        }
        return .rejectSavedKey
    }

    // MARK: - Private

    private func subscribeToReceiveAuthentication() {
        if link.isNotifying(.receiveAuthentication) {
            receiveAuthenticationReady = true
            startAuthenticationIfReady()
        } else {
            link.setNotify(true, for: .receiveAuthentication)
        }
    }

    /// Short path when a confirmed key exists, otherwise open J-PAKE with `0A 00`
    /// (DexcomG7AuthSession.swift:351-377, DexcomG7AuthBridge.m:188-201).
    private func startAuthenticationIfReady() {
        guard authStreamReady, receiveAuthenticationReady, !initialControlPacketSent, stage == .idle else { return }
        initialControlPacketSent = true
        stage = .authenticating
        if savedKey != nil {
            usingFullBootstrap = false
            delegate?.authSessionLog("auth: short authentication, slot \(slot.rawValue)")
            writeControl(makeAuthRequest())
            return
        }
        guard let pairingCode else {
            fail(.missingPairingCode)
            return
        }
        do {
            jpake = try makeJPAKE(pairingCode)
        } catch {
            fail(.pake(error))
            return
        }
        usingFullBootstrap = true
        delegate?.authSessionLog("auth: full J-PAKE bootstrap, slot \(slot.rawValue)")
        writeControl(G7PakeControl.request(phase: 0))
    }

    private func makeAuthRequest() -> Data {
        let token = randomBytes(G7AuthRequest.tokenLength)
        lastToken = token
        return G7AuthRequest.make(token: token, slot: slot)
    }

    private var keyForChallenge: [UInt8]? {
        usingFullBootstrap ? candidateKey : savedKey
    }

    /// DexcomG7AuthSession.swift:379-394 and DexcomG7AuthBridge.m:220-261. Only after our own `02`.
    private func handleChallenge(_ value: Data) {
        guard stage == .authenticating, lastToken != nil, !challengeResponseSent else {
            ignoreUnsolicited(value)
            return
        }
        guard let message = G7AuthChallengeMessage(value) else { return }
        guard let key = keyForChallenge else {
            fail(.protocolError("challenge received without a key"))
            return
        }
        // The token hash is diagnostic only: some firmware disagrees, and the challenge stays
        // authoritative (DexcomG7AuthBridge.m:237-249).
        if let token = lastToken, let expected = G7ChallengeHash.hash(token, key: key), expected != message.tokenHash {
            delegate?.authSessionLog("auth: sensor token hash differs from ours; continuing with the challenge")
        }
        guard let hash = G7ChallengeHash.hash(message.challenge, key: key) else {
            fail(.protocolError("challenge hash failed"))
            return
        }
        challengeResponseSent = true
        writeControl(G7AuthChallengeResponse.make(hash: hash))
    }

    /// DexcomG7AuthSession.swift:396-458, accepting only the `05` that answers our own `04`.
    private func handleStatus(_ value: Data) {
        if stage == .authenticated {
            // Already authenticated in this connection: a later "not authenticated" is surfaced and
            // ends the connection; anything else is not ours to act on.
            if let status = G7AuthStatusMessage(value), !status.authenticated {
                delegate?.authSessionLog("auth: 05 rejection after authentication; ending this connection")
                delegate?.authSessionSawRejectionAfterAuthentication()
            } else {
                ignoreUnsolicited(value)
            }
            return
        }
        guard stage == .authenticating, challengeResponseSent, !statusAnswered else {
            ignoreUnsolicited(value)
            return
        }
        statusAnswered = true
        guard let status = G7AuthStatusMessage(value) else {
            fail(.protocolError("unparseable authentication status"), packet: value)
            return
        }
        delegate?.authSessionLog("auth: status authenticated=\(status.authenticated) paired=\(status.paired)")
        switch Self.statusAction(usingFullBootstrap: usingFullBootstrap, authenticated: status.authenticated, paired: status.paired) {
        case .rejectSavedKey:
            // Do not erase the key and claim the slot again: another app may own it now, and
            // re-bootstrapping would evict it (DexcomG7AuthSession.swift:409-420, :460-462).
            stage = .failed
            delegate?.authSessionDidRejectSavedKey()
        case .startFullBootstrap:
            stage = .failed
            delegate?.authSessionNeedsFullBootstrap()
        case .reject:
            // The candidate key was never accepted; it must not survive (DexcomG7AuthSession.swift:436-441).
            candidateKey = nil
            fail(.pairingCodeRejected, packet: value)
        case .continueAuthentication:
            if usingFullBootstrap {
                guard !certificateExchangeStarted else { return }
                startCertificateExchange()
            } else if status.paired {
                stage = .authenticated
                delegate?.authSessionDidAuthenticate(newlyConfirmedKey: nil)
            }
        }
    }

    /// Each J-PAKE phase is exactly 160 remote bytes; process a phase only once both its control
    /// status and full payload are here, in either order (DexcomG7AuthSession.swift:491-514).
    private func processPendingPakeIfReady() {
        guard let phase = pendingPakePhase, authStreamBuffer.count >= G7JPAKEClient.payloadLength else { return }
        let payload = Array(authStreamBuffer[0..<G7JPAKEClient.payloadLength])
        authStreamBuffer.removeFirst(G7JPAKEClient.payloadLength)
        pendingPakePhase = nil
        guard let jpake else {
            fail(.protocolError("J-PAKE payload without a J-PAKE exchange"))
            return
        }
        do {
            let result = try jpake.handle(phase: phase, remotePayload: payload)
            expectedPakePhase = phase &+ 1
            let control: Data
            if let key = result.candidateSharedKey {
                // After phase 2 the next control packet is the auth request, answered with the
                // candidate key (DexcomG7AuthBridge.m:415-434).
                candidateKey = key
                control = makeAuthRequest()
            } else if let phaseControl = result.controlPacket {
                control = phaseControl
            } else {
                fail(.protocolError("J-PAKE phase \(phase) produced no control packet"))
                return
            }
            delegate?.authSessionLog("auth: J-PAKE phase \(phase) complete")
            writeExchange(streamPackets: Self.fragments(result.payload), controlPacket: control)
        } catch {
            fail(.pake(error))
        }
    }

    /// DexcomG7AuthSession.swift:516-532.
    private func startCertificateExchange() {
        certificateExchangeStarted = true
        stage = .certificateExchange
        expectedCertificatePhase = 0
        pendingCertificatePhase = nil
        pendingCertificateSize = nil
        authStreamBuffer.removeAll()
        writeControl(G7CertificateControl.request(phase: 0, certificateLength: UInt32(G7OwnershipCredentials.certificatePartA.count)))
    }

    /// DexcomG7AuthSession.swift:534-564.
    private func handleCertificateStatus(_ value: Data) {
        guard stage == .certificateExchange, let status = G7CertificateStatus(value) else {
            fail(.certificateExchangeRejected, packet: value)
            return
        }
        guard status.phase == expectedCertificatePhase, status.phase <= 2 else {
            fail(.protocolError("certificate phase out of order"), packet: value)
            return
        }
        // Bound the declared size before buffering; phase 2 carries nothing.
        guard status.size <= UInt32(Self.maximumCertificateSize), status.phase < 2 || status.size == 0 else {
            fail(.protocolError("certificate size invalid"), packet: value)
            return
        }
        pendingCertificatePhase = status.phase
        pendingCertificateSize = Int(status.size)
        processPendingCertificateIfReady()
    }

    /// The sensor's certificate bytes are consumed but not interpreted (as in xDrip4iOS); then our
    /// part for the phase is streamed and the next phase requested (DexcomG7AuthSession.swift:566-592).
    private func processPendingCertificateIfReady() {
        guard let phase = pendingCertificatePhase, let size = pendingCertificateSize, authStreamBuffer.count >= size else { return }
        authStreamBuffer.removeFirst(size)
        pendingCertificatePhase = nil
        pendingCertificateSize = nil
        expectedCertificatePhase = phase &+ 1
        guard let ours = G7OwnershipCredentials.certificate(forPhase: phase) else {
            fail(.protocolError("no certificate for phase \(phase)"))
            return
        }
        delegate?.authSessionLog("auth: certificate phase \(phase) complete (\(size) remote bytes)")
        if phase < 2 {
            let nextLength = G7OwnershipCredentials.certificate(forPhase: phase + 1)?.count ?? 0
            let next = G7CertificateControl.request(phase: phase + 1, certificateLength: UInt32(nextLength))
            writeExchange(streamPackets: Self.fragments(ours), controlPacket: next)
        } else {
            proofChallengeRequested = true
            writeControl(G7ProofControl.challengeRequest(challenge: randomBytes(G7ProofControl.challengeLength)))
        }
    }

    /// DexcomG7AuthSession.swift:594-605.
    private func handleProofChallenge(_ value: Data) {
        guard stage == .certificateExchange, let challenge = G7ProofChallenge(value) else {
            fail(.proofRejected, packet: value)
            return
        }
        pendingProofChallenge = challenge.challenge
        processPendingProofIfReady()
    }

    /// The sensor's 64-byte proof is consumed but not verified, exactly as in xDrip4iOS
    /// (DexcomG7AuthSession.swift:607-630); we sign its challenge and send `0D 00 02`.
    private func processPendingProofIfReady() {
        guard let challenge = pendingProofChallenge, authStreamBuffer.count >= Self.remoteProofLength else { return }
        authStreamBuffer.removeFirst(Self.remoteProofLength)
        pendingProofChallenge = nil
        let signature: [UInt8]
        do {
            signature = try G7OwnershipCredentials.proofSignature(forChallenge: challenge)
        } catch {
            fail(.protocolError("proof signing failed: \(error)"))
            return
        }
        stage = .proofOfPossession
        writeExchange(streamPackets: Self.fragments(signature), controlPacket: G7ProofControl.signatureSubmitted)
    }

    /// The key becomes trustworthy only now (DexcomG7AuthSession.swift:297-306, :326-334).
    private func completeOwnership(via message: String) {
        guard let key = candidateKey else {
            fail(.protocolError("ownership completed without a candidate key"))
            return
        }
        stage = .authenticated
        delegate?.authSessionLog("auth: ownership confirmed by \(message)")
        delegate?.authSessionDidAuthenticate(newlyConfirmedKey: key)
    }

    /// Stream fragments first, spaced 40 ms, then the control packet that tells the sensor to
    /// process them (DexcomG7AuthSession.swift:632-659).
    private func writeExchange(streamPackets: [[UInt8]], controlPacket: Data) {
        let generation = writeGeneration
        for (index, packet) in streamPackets.enumerated() where !packet.isEmpty {
            link.schedule(after: Self.streamPacketSpacing * Double(index)) { [weak self] in
                guard let self, self.writeGeneration == generation else { return }
                self.link.write(Data(packet), to: .authStream, withResponse: false)
            }
        }
        link.schedule(after: Self.streamPacketSpacing * Double(streamPackets.count + 1)) { [weak self] in
            guard let self, self.writeGeneration == generation else { return }
            self.writeControl(controlPacket)
        }
    }

    /// Another app's traffic on the shared link, a repeat, or a packet out of its stage.
    private func ignoreUnsolicited(_ value: Data) {
        delegate?.authSessionLog("auth: unsolicited \(value.hexString) ignored in stage \(stage.rawValue)")
    }

    private func writeControl(_ data: Data) {
        link.write(data, to: .receiveAuthentication, withResponse: true)
    }

    private func fail(_ failure: G7AuthFailure, packet: Data? = nil) {
        stage = .failed
        writeGeneration &+= 1
        delegate?.authSessionLog("auth: failed \(failure) packet=\(packet?.hexString ?? "none")")
        delegate?.authSessionDidFail(failure)
    }

    static func fragments(_ bytes: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: bytes.count, by: streamFragmentLength).map {
            Array(bytes[$0..<min($0 + streamFragmentLength, bytes.count)])
        }
    }
}

/// Cryptographically secure random bytes for tokens and challenges.
enum G7Random {
    static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
