// Ported from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0, like this project.
// The original file has no copyright header.
// Ported from xDrip4iOS xDrip/Managers/DexcomShare/DexcomShareUploadManager.swift @ 7.1.0 (0370937)
//   (uploadBgReadingsToDexcomShare :309-513)
//
// UNOFFICIAL AND SUBJECT TO BREAKING — see DexcomShareServer.swift.
//
// Dexcom Share upload (HANDOFF §8A step 2; PROGRESS D7: on for Michael, US region). Keeps
// existing Dexcom Follow users working after the Dexcom app is removed. Queueing, retry, backoff
// and the S2/S6 gate are `ReadingUploader`'s, exactly as for Nightscout; this type only speaks
// the Share protocol.
//
// Upload flow, as in xDrip4iOS (line numbers in DexcomShareUploadManager.swift):
//   no session id                        → log in first (:319-336)
//   2xx                                  → accepted (:394-400, :482-485)
//   SessionNotValid / SessionIdNotFound  → forget the session, log in again, retry once (:425-443)
//   MonitoringSessionNotActive           → StartRemoteMonitoringSession, then retry once (:445-450)
//   DuplicateEgvPosted                   → treated as accepted (:452-455); see below
//   MonitoredReceiverSerialNumberDoesNotMatch / MonitoredReceiverNotAssigned
//                                        → configuration error for Settings (:456-472)
//   anything else                        → error, readings stay queued (:474-478)
// Differences, on purpose: retries are bounded to one re-login and one session start per upload
// (xDrip4iOS can loop on MonitoringSessionNotActive); readings come from our queue, not from a
// "last uploaded timestamp"; and DuplicateEgvPosted for a batch of several readings re-posts them
// one by one, because Share's behaviour for a batch mixing new and already-posted readings is
// undocumented — posting singly guarantees every new reading is accepted exactly once.

import Foundation
import GlucoseCore

public actor DexcomShareUploadDestination: UploadDestination {
    public nonisolated let name = "Dexcom Share"
    /// 8 hours of 5-minute readings: everything xDrip4iOS would send at once
    /// (DexcomShareUploadManager.swift:338-345).
    public nonisolated let maxBatchSize = 96
    /// Readings older than 8 hours are not sent (DexcomShareUploadManager.swift:338-339).
    public nonisolated let maxReadingAge: TimeInterval? = DexcomShareConstants.maxReadingAge

    private let client: DexcomShareClient
    private let receiverSerialNumber: String
    private var sessionID: String?

    /// - Parameter receiverSerialNumber: the receiver/upload serial number assigned to the Dexcom
    ///   account ("SN", DexcomShareUploadManager.swift:365); not the G7 pairing code (see
    ///   docs/following.md). Upper-cased as xDrip4iOS does (SettingsViewDexcomShareSettingsViewModel.swift:93).
    public init(
        server: DexcomShareServer,
        receiverSerialNumber: String,
        credentials: any CredentialStore,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.client = DexcomShareClient(server: server, credentials: credentials, transport: transport)
        self.receiverSerialNumber = receiverSerialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Only numeric values 40...400: Share has no documented LOW/HIGH representation (S4;
    /// DexcomShareEGV.swift).
    public nonisolated func canRepresent(_ value: GlucoseValue) -> Bool {
        if case .mgdl(let mgdl) = value { return GlucoseValue.sensorReportableRange.contains(mgdl) }
        return false
    }

    public func upload(_ readings: [GlucoseReading]) async throws(UploadError) {
        guard !receiverSerialNumber.isEmpty else {
            throw UploadError(.configuration, "Dexcom Share receiver serial number is not set")
        }
        let egvs = readings.compactMap(DexcomShareEGV.init(reading:))
        guard egvs.count == readings.count else {
            // `ReadingUploader` never queues these (canRepresent); refusing here keeps S4 local.
            throw UploadError(.configuration, "a queued reading has no Dexcom Share representation")
        }
        guard !egvs.isEmpty else { return }
        // Newest first, as xDrip4iOS sends them (getLatestBgReadings order, :345, :362).
        let newestFirst = zip(readings, egvs).sorted { $0.0.date > $1.0.date }.map(\.1)
        try await post(newestFirst, mayLogInAgain: true, mayStartSession: true)
    }

    private func post(_ egvs: [DexcomShareEGV], mayLogInAgain: Bool, mayStartSession: Bool) async throws(UploadError) {
        let session = try await currentSession()
        let body = DexcomShareUploadBody(egvs: egvs, serialNumber: receiverSerialNumber, ta: DexcomShareConstants.uploadTA)
        switch try await client.postReceiverEgvRecords(sessionID: session, body: body) {
        case .accepted:
            return
        case .rejected(let code, let statusCode):
            switch code {
            case DexcomShareConstants.ErrorCode.sessionNotValid, DexcomShareConstants.ErrorCode.sessionIDNotFound:
                sessionID = nil
                guard mayLogInAgain else { throw UploadError(.server, "Dexcom Share session rejected again after a new login") }
                try await post(egvs, mayLogInAgain: false, mayStartSession: mayStartSession)

            case DexcomShareConstants.ErrorCode.monitoringSessionNotActive:
                guard mayStartSession else { throw UploadError(.server, "Dexcom Share monitoring session did not start") }
                try await startMonitoringSession(session)
                try await post(egvs, mayLogInAgain: mayLogInAgain, mayStartSession: false)

            case DexcomShareConstants.ErrorCode.duplicateEgvPosted:
                if egvs.count == 1 { return }
                for egv in egvs {
                    try await post([egv], mayLogInAgain: mayLogInAgain, mayStartSession: mayStartSession)
                }

            case DexcomShareConstants.ErrorCode.monitoredReceiverSerialNumberDoesNotMatch:
                throw UploadError(.configuration, "Dexcom Share: the receiver serial number does not match this account")

            case DexcomShareConstants.ErrorCode.monitoredReceiverNotAssigned:
                throw UploadError(.configuration, "Dexcom Share: the receiver serial number is not assigned to this account")

            case .some(let code):
                throw UploadError(.server, "Dexcom Share rejected the upload: \(code) (HTTP \(statusCode))")

            case .none:
                throw UploadError(.server, "Dexcom Share rejected the upload (HTTP \(statusCode))")
            }
        }
    }

    /// StartRemoteMonitoringSession for our serial (DexcomShareUploadManager.swift:182-301).
    private func startMonitoringSession(_ session: String) async throws(UploadError) {
        switch try await client.startRemoteMonitoringSession(sessionID: session, serialNumber: receiverSerialNumber) {
        case .accepted:
            return
        case .rejected(let code, let statusCode):
            switch code {
            case DexcomShareConstants.ErrorCode.monitoredReceiverSerialNumberDoesNotMatch:
                throw UploadError(.configuration, "Dexcom Share: the receiver serial number does not match this account")
            case DexcomShareConstants.ErrorCode.monitoredReceiverNotAssigned:
                throw UploadError(.configuration, "Dexcom Share: the receiver serial number is not assigned to this account")
            case DexcomShareConstants.ErrorCode.sessionNotValid, DexcomShareConstants.ErrorCode.sessionIDNotFound:
                sessionID = nil
                throw UploadError(.server, "Dexcom Share session expired while starting monitoring")
            default:
                throw UploadError(.server, "Dexcom Share could not start monitoring: \(code ?? "HTTP \(statusCode)")")
            }
        }
    }

    private func currentSession() async throws(UploadError) -> String {
        if let sessionID { return sessionID }
        let fresh = try await client.login()
        sessionID = fresh
        return fresh
    }
}

extension ReadingUploader {
    /// Dexcom Share uploader persisting its queue at `<queueDirectory>/dexcom-share-upload-queue.json`.
    /// UNOFFICIAL AND SUBJECT TO BREAKING — see DexcomShareServer.swift.
    public static func dexcomShare(
        server: DexcomShareServer,
        receiverSerialNumber: String,
        credentials: any CredentialStore,
        queueDirectory: URL,
        transport: any HTTPTransport = URLSessionTransport(),
        retryPolicy: RetryPolicy = .default,
        clock: any WallClock = SystemWallClock(),
        log: any DiagnosticLog = NullDiagnosticLog()
    ) -> ReadingUploader {
        ReadingUploader(
            destination: DexcomShareUploadDestination(
                server: server, receiverSerialNumber: receiverSerialNumber, credentials: credentials, transport: transport
            ),
            queueFile: queueDirectory.appendingPathComponent("dexcom-share-upload-queue.json"),
            retryPolicy: retryPolicy,
            clock: clock,
            log: log
        )
    }
}
