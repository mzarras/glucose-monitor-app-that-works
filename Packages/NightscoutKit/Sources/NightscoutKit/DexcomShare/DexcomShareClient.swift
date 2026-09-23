// Ported from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0, like this project.
// The original file has no copyright header.
// Ported from xDrip4iOS xDrip/Managers/DexcomShare/DexcomShareUploadManager.swift @ 7.1.0 (0370937)
//   (loginAndStoreSessionId :528-679, startRemoteMonitoringSessionAndStartUpload :182-301,
//    createURLRequestForUploadBgReadings :744-774)
//
// UNOFFICIAL AND SUBJECT TO BREAKING — see DexcomShareServer.swift.
//
// The three HTTP calls of the Share upload protocol, rewritten with async/await and without
// UserDefaults. The account name and password come from the Keychain (`CredentialStore`) at
// each login and never appear in errors or diagnostics. Share itself requires the session id in
// the query string (DexcomShareUploadManager.swift:201, 759), so request URLs are never logged.

import Foundation

struct DexcomShareClient: Sendable {
    /// What Share answered to an upload or start-session call.
    enum Answer: Sendable, Equatable {
        /// 2xx. An empty body means success; a non-empty 2xx body is also treated as success
        /// (DexcomShareUploadManager.swift:394-400 and :482-485).
        case accepted
        /// Non-2xx. `code` is the `Code` field of Share's JSON error body, if there is one
        /// (DexcomShareUploadManager.swift:419-420).
        case rejected(code: String?, statusCode: Int)
    }

    let server: DexcomShareServer
    let credentials: any CredentialStore
    let transport: any HTTPTransport

    // MARK: - Login (two steps)

    private struct AuthenticateBody: Encodable {
        let accountName: String
        let password: String
        let applicationId: String
    }

    private struct LoginBody: Encodable {
        let accountId: String
        let password: String
        let applicationId: String
    }

    /// Returns a Share session id (DexcomShareUploadManager.swift:528-679).
    func login() async throws(UploadError) -> String {
        let accountName: String?
        let password: String?
        do {
            accountName = try credentials.read(.dexcomShareAccountName)
            password = try credentials.read(.dexcomSharePassword)
        } catch {
            throw UploadError(.missingCredentials, "Could not read Dexcom Share credentials: \(error.message)")
        }
        guard let accountName, !accountName.isEmpty, let password, !password.isEmpty else {
            throw UploadError(.missingCredentials, "Dexcom Share account name or password is not set")
        }

        // Step 1/2 — AuthenticatePublisherAccount: name + password → account id (:541-595).
        let accountID = try await postForQuotedString(
            path: DexcomShareConstants.authenticatePath,
            body: AuthenticateBody(accountName: accountName, password: password, applicationId: DexcomShareConstants.applicationID)
        )
        // Step 2/2 — LoginPublisherAccountById: account id + password → session id (:597-661).
        let sessionID = try await postForQuotedString(
            path: DexcomShareConstants.loginPath,
            body: LoginBody(accountId: accountID, password: password, applicationId: DexcomShareConstants.applicationID)
        )
        // An all-zero session id means the password was wrong (:654-657).
        guard sessionID != DexcomShareConstants.failedSessionID else {
            throw UploadError(.unauthorized, "Dexcom Share rejected the account name or password")
        }
        return sessionID
    }

    /// POSTs a login body and returns the JSON string the server answers with, without its quotes
    /// (DexcomShareUploadManager.swift:590, 647).
    private func postForQuotedString(path: String, body: some Encodable) async throws(UploadError) -> String {
        var request = URLRequest(url: server.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DexcomShareConstants.loginUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw UploadError(.configuration, "Could not encode Dexcom Share login")
        }
        let response = try await send(request)
        guard response.isSuccess else {
            throw Self.loginError(code: Self.errorCode(in: response.body), statusCode: response.statusCode)
        }
        let text = (String(data: response.body, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !text.isEmpty else { throw UploadError(.server, "Dexcom Share login returned no id") }
        return text
    }

    /// Login error codes (DexcomShareUploadManager.swift:713-727).
    static func loginError(code: String?, statusCode: Int) -> UploadError {
        switch code {
        case DexcomShareConstants.ErrorCode.accountNotFound, DexcomShareConstants.ErrorCode.passwordInvalid:
            return UploadError(.unauthorized, "Dexcom Share rejected the account name or password")
        case DexcomShareConstants.ErrorCode.maxAttemptsExceeded:
            return UploadError(.unauthorized, "Dexcom Share: too many login attempts; wait before retrying")
        case .some(let code):
            return UploadError(.server, "Dexcom Share login failed: \(code) (HTTP \(statusCode))")
        case .none:
            return UploadError(.server, "Dexcom Share login failed (HTTP \(statusCode))")
        }
    }

    // MARK: - Upload and remote monitoring session

    /// POST Publisher/PostReceiverEgvRecords?sessionId=… (DexcomShareUploadManager.swift:744-774,
    /// 355-378). Headers as in createURLRequestForUploadBgReadings (:767-771).
    func postReceiverEgvRecords(sessionID: String, body: DexcomShareUploadBody) async throws(UploadError) -> Answer {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw UploadError(.configuration, "Could not encode Dexcom Share readings")
        }
        let request = try publisherRequest(
            path: DexcomShareConstants.postReceiverEgvRecordsPath,
            query: [URLQueryItem(name: "sessionId", value: sessionID)],
            body: data,
            acceptJSON: true
        )
        return try await answer(for: request)
    }

    /// POST Publisher/StartRemoteMonitoringSession?sessionId=…&serialNumber=… with an empty body
    /// (DexcomShareUploadManager.swift:191-218).
    func startRemoteMonitoringSession(sessionID: String, serialNumber: String) async throws(UploadError) -> Answer {
        let request = try publisherRequest(
            path: DexcomShareConstants.startRemoteMonitoringSessionPath,
            query: [URLQueryItem(name: "sessionId", value: sessionID), URLQueryItem(name: "serialNumber", value: serialNumber)],
            body: Data(),
            acceptJSON: false
        )
        return try await answer(for: request)
    }

    private func publisherRequest(path: String, query: [URLQueryItem], body: Data, acceptJSON: Bool) throws(UploadError) -> URLRequest {
        guard var components = URLComponents(url: server.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw UploadError(.configuration, "Could not build Dexcom Share URL")
        }
        components.queryItems = query
        guard let url = components.url else { throw UploadError(.configuration, "Could not build Dexcom Share URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if acceptJSON { request.setValue("application/json", forHTTPHeaderField: "Accept") }
        request.setValue(DexcomShareConstants.publisherUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func answer(for request: URLRequest) async throws(UploadError) -> Answer {
        let response = try await send(request)
        if response.isSuccess { return .accepted }
        return .rejected(code: Self.errorCode(in: response.body), statusCode: response.statusCode)
    }

    private func send(_ request: URLRequest) async throws(UploadError) -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch {
            throw UploadError(.transport, "Could not reach Dexcom Share: \(error.message)")
        }
    }

    /// The `Code` field of a Share JSON error body, e.g. {"Code":"SessionNotValid","Message":…}.
    static func errorCode(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) as? [String: Any] else {
            return nil
        }
        return object["Code"] as? String
    }
}
