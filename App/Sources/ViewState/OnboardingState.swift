// Onboarding / pairing (HANDOFF §4.5, §4.6, §7.3.5, §8A, PROGRESS D7). Phase 2 drives `step`
// and fills permission and import progress from the system and NightscoutKit.

import Foundation
import GlucoseCore

enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case importHistory
    case removeDexcomApp
    case permissions
    case pairing
    case warmUp

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

enum PermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// Nightscout import depth (HANDOFF §4.5: 90 days by default, option for everything).
enum ImportDepth: String, CaseIterable, Identifiable, Sendable {
    case ninetyDays
    case everything

    var id: String { rawValue }
    var label: String { self == .ninetyDays ? "Last 90 days" : "Everything" }
}

/// Progress of a running (or finished) history import.
struct ImportProgress: Equatable, Sendable {
    var origin: ImportOrigin
    var readingsImported: Int
    /// Date range covered so far.
    var covered: DateInterval?
    var isFinished: Bool
    var errorMessage: String?
}

enum PairingState: Equatable, Sendable {
    case idle
    /// Code sent; waiting for the sensor (and the iOS pairing prompt).
    case inProgress
    case failed(message: String)
    case paired
}

struct OnboardingState: Equatable, Sendable {
    var step: OnboardingStep
    var importProgress: ImportProgress?
    var bluetooth: PermissionState
    var notifications: NotificationPermission
    var criticalAlerts: CriticalAlertsStatus
    /// Offer Dexcom Share upload so Dexcom Follow keeps working (D7: on, US preselected).
    var shareUploadEnabled: Bool
    var shareRegion: ShareRegion
    var pairing: PairingState
    /// For the warm-up countdown on the last step.
    var sensorState: SensorState

    static let initial = OnboardingState(
        step: .welcome,
        importProgress: nil,
        bluetooth: .notDetermined,
        notifications: .notDetermined,
        criticalAlerts: .entitlementNotGranted,
        shareUploadEnabled: true,
        shareRegion: .default,
        pairing: .idle,
        sensorState: .notPaired
    )
}

enum OnboardingText {
    /// "12,408 readings imported · Jun 25 – Sep 23"
    static func importProgress(_ progress: ImportProgress, context: DisplayContext = .current) -> String {
        let count = progress.readingsImported.formatted(.number.locale(context.locale))
        let noun = progress.readingsImported == 1 ? "reading" : "readings"
        guard let covered = progress.covered else { return "\(count) \(noun) imported" }
        let start = TimeText.shortDay(covered.start, context)
        let end = TimeText.shortDay(covered.end, context)
        return "\(count) \(noun) imported · \(start) – \(end)"
    }
}

/// The sensor's 4-digit pairing code (HANDOFF §4.6: the J-PAKE secret).
enum PairingCode {
    static let length = 4

    /// Keeps ASCII digits only, at most four.
    static func sanitize(_ input: String) -> String {
        String(input.filter { $0.isASCII && $0.isNumber }.prefix(length))
    }

    static func isComplete(_ code: String) -> Bool {
        code.count == length && code.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
