import Foundation
import GlucoseCore
@testable import AlertEngine

/// Records what would have been handed to UNUserNotificationCenter.
@MainActor
final class FakeNotificationCenter: AlertNotificationCenter {
    var permissions = NotificationPermissionState(
        authorization: .authorized, alerts: .enabled, sounds: .enabled, criticalAlerts: .notSupported, timeSensitive: .enabled
    )
    var permissionsAfterRequest: NotificationPermissionState?
    var failAdds = false
    private(set) var categoriesRegistered = 0
    private(set) var authorizationRequests = 0
    /// Pending requests (with a fire date) by identifier.
    private(set) var pending: [String: NotificationRequestSpec] = [:]
    /// Requests delivered immediately, in order.
    private(set) var posted: [NotificationRequestSpec] = []
    /// Delivered notifications still showing, by identifier.
    private(set) var delivered: [String: NotificationRequestSpec] = [:]
    private(set) var removedPending: [String] = []
    private(set) var removedDelivered: [String] = []

    func registerCategories() async { categoriesRegistered += 1 }

    func requestAuthorization() async -> NotificationPermissionState {
        authorizationRequests += 1
        if let next = permissionsAfterRequest { permissions = next }
        return permissions
    }

    private(set) var permissionChecks = 0

    func permissionState() async -> NotificationPermissionState {
        permissionChecks += 1
        return permissions
    }

    struct AddFailed: Error {}

    func add(_ request: NotificationRequestSpec) async throws {
        if failAdds { throw AddFailed() }
        if request.fireDate == nil {
            posted.append(request)
            delivered[request.identifier] = request
        } else {
            pending[request.identifier] = request
        }
    }

    func removePending(identifiers: [String]) {
        removedPending += identifiers
        for id in identifiers { pending[id] = nil }
    }

    func removeDelivered(identifiers: [String]) {
        removedDelivered += identifiers
        for id in identifiers { delivered[id] = nil }
    }

    func pending(for kind: AlertKind) -> [NotificationRequestSpec] {
        pending.values.filter { $0.userInfo[AlertNotificationIDs.userInfoKind] == kind.rawValue }
            .sorted { ($0.fireDate ?? .distantPast) < ($1.fireDate ?? .distantPast) }
    }
}

@MainActor
final class FakeAudioPlayer: AlertAudioPlaying {
    var startsSuccessfully = true
    var outputVolume: Float? = 0.8
    private(set) var plays: [(fileName: String, loopSeconds: TimeInterval)] = []
    private(set) var stops = 0
    private(set) var isPlaying = false

    func play(fileName: String, loopSeconds: TimeInterval) -> Bool {
        plays.append((fileName, loopSeconds))
        isPlaying = startsSuccessfully
        return startsSuccessfully
    }

    func stop() {
        stops += 1
        isPlaying = false
    }

    /// The sound finished on its own.
    func finish() { isPlaying = false }
}

final class RecordingDiagnosticLog: DiagnosticLog, @unchecked Sendable {
    // @unchecked: test-only; every access is serialised by the lock.
    private let lock = NSLock()
    private var storage: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        storage.append(event)
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.map(\.message)
    }
}

/// Stands in for AlarmKit: records scheduled alarms by ID, can refuse.
@MainActor
final class FakeSystemAlarms: SystemAlarmScheduling {
    var authorization: SystemAlarmAuthorization = .authorized
    var authorizationAfterRequest: SystemAlarmAuthorization?
    /// Fail every schedule call with this error, or only from the n-th call (0-based) if set.
    var failWith: Error?
    var failFromCall: Int = 0
    private(set) var scheduleCalls = 0
    private(set) var scheduled: [UUID: SystemAlarmRequest] = [:]
    private(set) var cancelAllCalls = 0

    struct Refused: Error, CustomStringConvertible {
        var description: String { "maximumLimitReached" }
    }

    func requestAuthorization() async -> SystemAlarmAuthorization {
        if let next = authorizationAfterRequest { authorization = next }
        return authorization
    }

    func schedule(_ request: SystemAlarmRequest) async throws {
        defer { scheduleCalls += 1 }
        if let failWith, scheduleCalls >= failFromCall { throw failWith }
        scheduled[request.id] = request
    }

    func cancel(ids: [UUID]) {
        for id in ids { scheduled[id] = nil }
    }

    func cancelAll() {
        cancelAllCalls += 1
        scheduled = [:]
    }

    var repeatAlarms: [SystemAlarmRequest] {
        scheduled.values.filter { $0.id != SystemAlarmIDs.immediate }.sorted { $0.fireDate < $1.fireDate }
    }
}
