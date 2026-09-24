// Onboarding / pairing (HANDOFF §4.5, §4.6, §7.3.5, §8A, PROGRESS D7). Phase 2 drives `step`
// and fills permission and import progress from the system and NightscoutKit.

import Foundation
import GlucoseCore

enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case importHistory
    case removeDexcomApp
    case permissions
    /// D26: allow AlarmKit alarms for urgent low. Only where AlarmKit exists (iOS 26+).
    case alarms
    case pairing
    case warmUp

    /// The steps shown, in order: `.alarms` only when AlarmKit is available.
    static func visibleSteps(alarmsAvailable: Bool) -> [OnboardingStep] {
        allCases.filter { $0 != .alarms || alarmsAvailable }
    }

    func next(alarmsAvailable: Bool) -> OnboardingStep? {
        let steps = Self.visibleSteps(alarmsAvailable: alarmsAvailable)
        guard let index = steps.firstIndex(of: self), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    func previous(alarmsAvailable: Bool) -> OnboardingStep? {
        let steps = Self.visibleSteps(alarmsAvailable: alarmsAvailable)
        guard let index = steps.firstIndex(of: self), index > 0 else { return nil }
        return steps[index - 1]
    }
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
    /// The source's failure (D36), e.g. `bluetoothPairingIncomplete`, `pairingRejected`,
    /// `pairingCodeNeeded`; shown with its message.
    case failed(SensorFailure)
    case paired
}

struct OnboardingState: Equatable, Sendable {
    var step: OnboardingStep
    var importProgress: ImportProgress?
    var bluetooth: PermissionState
    var notifications: NotificationPermission
    var criticalAlerts: CriticalAlertsStatus
    /// D26: AlarmKit authorization; `.unavailable` hides the Alarms step.
    var urgentLowAlarm: UrgentLowAlarmStatus
    /// Offer Dexcom Share upload so Dexcom Follow keeps working (D7: on, US preselected).
    var shareUploadEnabled: Bool
    var shareRegion: ShareRegion
    var pairing: PairingState
    /// For the warm-up countdown on the last step.
    var sensorState: SensorState

    var alarmsAvailable: Bool { urgentLowAlarm.isAvailable }
    var visibleSteps: [OnboardingStep] { OnboardingStep.visibleSteps(alarmsAvailable: alarmsAvailable) }

    static let initial = OnboardingState(
        step: .welcome,
        importProgress: nil,
        bluetooth: .notDetermined,
        notifications: .notDetermined,
        criticalAlerts: .entitlementNotGranted,
        urgentLowAlarm: .defaultForThisOS,
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

extension OnboardingText {
    /// Headline for a failed pairing; the detail is always the source's own message (D36).
    static func pairingFailureTitle(_ failure: SensorFailure) -> String {
        switch failure.kind {
        case .bluetoothPairingIncomplete: return "Pairing didn't finish"
        case .pairingRejected: return "The sensor didn't accept this phone"
        case .pairingCodeNeeded: return "Enter the pairing code"
        case .bondRemoved: return "The sensor forgot this phone"
        case .otherAppRejected: return "Another app is connected to the sensor"
        default: return failure.requiresSensorReplacement ? "This sensor can't be used" : "Pairing failed"
        }
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
