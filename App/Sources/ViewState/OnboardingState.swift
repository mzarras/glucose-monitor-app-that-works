// Onboarding / pairing (HANDOFF §4.5, §4.6, §7.3.5, §8A, PROGRESS D7, D35). `AppModel` drives
// `step` and fills permissions, import progress and pairing from `AppServices` (`OnboardingMapping`).

import Foundation
import GlucoseCore

enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    /// D45: listen alongside the Dexcom app, or pair this app. Only once the facade offers listen
    /// mode (`OnboardingState.connection` non-nil).
    case connection
    case importHistory
    case removeDexcomApp
    case permissions
    /// D26: allow AlarmKit alarms for urgent low. Only where AlarmKit exists (iOS 26+).
    case alarms
    case pairing
    /// D45: waiting for the Dexcom app's connection, instead of removing it and pairing.
    case listen
    case warmUp

    /// The steps shown, in order: `.alarms` only when AlarmKit is available; `.connection` only
    /// when listen mode is offered (`connection` non-nil); listening skips removing the Dexcom app
    /// and pairing (`.listen` instead), anything else (pairing, or not chosen yet) keeps them.
    static func visibleSteps(alarmsAvailable: Bool, connection: ConnectionModeState? = nil) -> [OnboardingStep] {
        allCases.filter { step in
            switch step {
            case .alarms: return alarmsAvailable
            case .connection: return connection != nil
            case .removeDexcomApp, .pairing: return connection?.isListening != true
            case .listen: return connection?.isListening == true
            case .welcome, .importHistory, .permissions, .warmUp: return true
            }
        }
    }

    func next(alarmsAvailable: Bool, connection: ConnectionModeState? = nil) -> OnboardingStep? {
        let steps = Self.visibleSteps(alarmsAvailable: alarmsAvailable, connection: connection)
        guard let index = steps.firstIndex(of: self), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    func previous(alarmsAvailable: Bool, connection: ConnectionModeState? = nil) -> OnboardingStep? {
        let steps = Self.visibleSteps(alarmsAvailable: alarmsAvailable, connection: connection)
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
    /// Stopped by the person; what was imported is kept.
    var isCancelled: Bool = false
    /// Readings dated in the future that were rejected (a wrong time zone or clock fault; PROGRESS
    /// Phase 2 must-do: show `rejectedFutureDated`).
    var rejectedFutureDated: Int = 0
    /// Entries skipped before storing, and readings the store already had, as one line; nil if none.
    var skippedNote: String? = nil

    var isRunning: Bool { !isFinished && !isCancelled && errorMessage == nil }
}

enum PairingState: Equatable, Sendable {
    case idle
    /// Code sent; waiting for the sensor (and the iOS pairing prompt).
    case inProgress
    /// The source's failure (D36), e.g. `bluetoothPairingIncomplete`, `pairingRejected`,
    /// `pairingCodeNeeded`; shown with its message.
    case failed(SensorFailure)
    /// The app refused the code before anything reached the sensor (`PairingError`).
    case couldNotStart(String)
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
    /// A Nightscout site is saved (import from it without typing it again).
    var nightscoutSiteURL: String? = nil
    var nightscoutHasToken: Bool = false
    /// Why saving the Nightscout site or Share credentials failed, for the step that asked.
    var nightscoutMessage: String? = nil
    var shareMessage: String? = nil
    /// Review M1: every step offers "Set up later", so onboarding is never a trap (without a new
    /// sensor, the pairing step has no other way out).
    var isDismissible: Bool = true
    /// D45: the connection step's choice (nil mode until chosen). Nil for a fixture without it.
    var connection: ConnectionModeState? = nil
    /// D45: the mode the facade is in now; Continue on the connection step switches to the choice
    /// when they differ.
    var currentConnectionMode: SensorConnectionMode = .pair
    /// D45: switching would replace a stored sensor's pairing, so Continue asks first.
    var connectionSwitchNeedsConfirmation: Bool = false
    /// D45: a switch is on its way, or why it didn't happen (nothing changed).
    var connectionSwitching: Bool = false
    var connectionMessage: String? = nil

    var alarmsAvailable: Bool { urgentLowAlarm.isAvailable }
    var visibleSteps: [OnboardingStep] { OnboardingStep.visibleSteps(alarmsAvailable: alarmsAvailable, connection: connection) }
    /// The step after (before) `step` in this flow.
    func step(after step: OnboardingStep) -> OnboardingStep? { step.next(alarmsAvailable: alarmsAvailable, connection: connection) }
    func step(before step: OnboardingStep) -> OnboardingStep? { step.previous(alarmsAvailable: alarmsAvailable, connection: connection) }

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

    /// PROGRESS D35 (review): another primary-mode G7 app on this phone can disconnect this one or
    /// have a reading attributed to it; only one app may be the sensor's primary device.
    static let otherG7AppsWarning = "Remove or turn off every other app that connects to G7 sensors — the Dexcom G7 app, xDrip4iOS, and Trio's or Loop's own G7 connection. Only one app can be the sensor's primary device; a second one interrupts readings and can make them unreliable."
}

enum OnboardingText {
    /// A stopped import's message in full (NightscoutKit's `unusableHistory` names the date range
    /// and what to do), followed by what happens to the imported readings unless it says so itself.
    static func importFailure(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = trimmed.hasSuffix(".") ? trimmed : trimmed + "."
        if trimmed.localizedCaseInsensitiveContains("imported so far are kept") { return sentence }
        return "\(sentence) Already-imported readings are kept; running the import again continues where it stopped."
    }

    /// Import readings dated in the future and left out (PROGRESS D33: a wrong time zone or a clock
    /// fault; never stored as readings), nil when there were none.
    static func futureDatedNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count.formatted()) \(count == 1 ? "reading was" : "readings were") dated in the future and left out. Check the time zone chosen for the import."
    }

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
