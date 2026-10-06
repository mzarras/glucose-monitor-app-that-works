// Original to Sensor (no ported code).
// A mock of the Dexcom Share publisher endpoints as xDrip4iOS 7.1.0 uses them
// (DexcomShareUploadManager.swift): two-step login, StartRemoteMonitoringSession, and
// PostReceiverEgvRecords with its error codes. Duplicate handling is deliberately pessimistic: a
// batch containing any already-posted EGV is rejected whole with DuplicateEgvPosted and nothing
// is stored, so the uploader must still get every new reading in exactly once.

import Foundation
@testable import NightscoutKit

actor MockShareServer: MockBackend {
    struct PostedEGV: Codable, Equatable, Sendable {
        let Trend: Int
        let ST: String
        let DT: String
        let Value: Int
        let direction: String
    }

    struct UploadBody: Codable, Equatable, Sendable {
        let Egvs: [PostedEGV]
        let SN: String
        let TA: Int
    }

    static let accountName = "synthetic-share-user"
    static let password = "synthetic-share-password"
    static let accountID = "11111111-2222-3333-4444-555555555555"
    static let applicationID = "d89443d2-327c-4a6f-89e5-496bbb0317db"

    /// The receiver serial assigned to the account; `nil` = none assigned.
    var assignedSerial: String? = "SM12345678"
    private(set) var requests: [MockHTTPRequest] = []
    private(set) var stored: [PostedEGV] = []
    private(set) var uploadBodies: [UploadBody] = []
    private(set) var logins = 0
    private(set) var monitoringStarts = 0
    private var sessions: Set<String> = []
    private var monitoringActive = false
    private var nextSession = 1
    var offline = false
    /// Replies used, in order, for the next PostReceiverEgvRecords / StartRemoteMonitoringSession
    /// calls instead of handling them (login calls are always handled).
    var scriptedPublisherReplies: [MockReply] = []

    func setAssignedSerial(_ serial: String?) { assignedSerial = serial }
    func setOffline(_ value: Bool) { offline = value }
    /// Share forgets every session (e.g. expiry); the next upload gets SessionNotValid.
    func expireSessions() { sessions.removeAll() }
    /// Monitoring stops; the next upload gets MonitoringSessionNotActive.
    func stopMonitoring() { monitoringActive = false }
    func seed(_ egv: PostedEGV) { stored.append(egv) }
    func scriptPublisher(_ replies: [MockReply]) { scriptedPublisherReplies = replies }

    func handle(_ request: MockHTTPRequest) async -> MockReply {
        requests.append(request)
        if offline { return .transportFailure("offline") }
        guard request.method == "POST", request.path.hasPrefix("/ShareWebServices/Services/") else { return .status(404) }
        let endpoint = String(request.path.dropFirst("/ShareWebServices/Services/".count))
        if endpoint.hasPrefix("Publisher/"), !scriptedPublisherReplies.isEmpty { return scriptedPublisherReplies.removeFirst() }
        switch endpoint {
        case "General/AuthenticatePublisherAccount": return authenticate(request)
        case "General/LoginPublisherAccountById": return login(request)
        case "Publisher/StartRemoteMonitoringSession": return startMonitoring(request)
        case "Publisher/PostReceiverEgvRecords": return post(request)
        default: return .status(404)
        }
    }

    private func object(_ request: MockHTTPRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: request.body) as? [String: String]) ?? [:]
    }

    private func authenticate(_ request: MockHTTPRequest) -> MockReply {
        let body = object(request)
        guard body["applicationId"] == Self.applicationID else { return .json(500, ["Code": "InvalidApplicationId"]) }
        guard body["accountName"] == Self.accountName else { return .json(500, ["Code": "SSO_AuthenticateAccountNotFound"]) }
        // A wrong password is only detected in step 2 (all-zero session id), as xDrip4iOS expects.
        return .json(200, Self.accountID)
    }

    private func login(_ request: MockHTTPRequest) -> MockReply {
        let body = object(request)
        guard body["applicationId"] == Self.applicationID, body["accountId"] == Self.accountID else {
            return .json(500, ["Code": "SSO_AuthenticateAccountNotFound"])
        }
        logins += 1
        guard body["password"] == Self.password else { return .json(200, "00000000-0000-0000-0000-000000000000") }
        let session = "session-\(nextSession)"
        nextSession += 1
        sessions.insert(session)
        return .json(200, session)
    }

    private func startMonitoring(_ request: MockHTTPRequest) -> MockReply {
        guard let session = request.query("sessionId"), sessions.contains(session) else { return .json(500, ["Code": "SessionIdNotFound"]) }
        guard let assignedSerial else { return .json(500, ["Code": "MonitoredReceiverNotAssigned"]) }
        guard request.query("serialNumber") == assignedSerial else { return .json(500, ["Code": "MonitoredReceiverSerialNumberDoesNotMatch"]) }
        monitoringStarts += 1
        monitoringActive = true
        return .status(200)
    }

    private func post(_ request: MockHTTPRequest) -> MockReply {
        guard let session = request.query("sessionId"), sessions.contains(session) else { return .json(500, ["Code": "SessionNotValid"]) }
        guard let body = try? JSONDecoder().decode(UploadBody.self, from: request.body) else { return .json(400, ["Code": "InvalidArgument"]) }
        uploadBodies.append(body)
        guard let assignedSerial else { return .json(500, ["Code": "MonitoredReceiverNotAssigned"]) }
        guard body.SN == assignedSerial else { return .json(500, ["Code": "MonitoredReceiverSerialNumberDoesNotMatch"]) }
        guard monitoringActive else { return .json(500, ["Code": "MonitoringSessionNotActive"]) }
        let existing = Set(stored.map(\.ST))
        if body.Egvs.contains(where: { existing.contains($0.ST) }) { return .json(500, ["Code": "DuplicateEgvPosted"]) }
        stored.append(contentsOf: body.Egvs)
        return .status(200)
    }
}
