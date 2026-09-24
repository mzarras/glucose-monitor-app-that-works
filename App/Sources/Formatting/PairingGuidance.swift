// What the UI offers the person for each pairing-related sensor failure (D36/D37 review M1,
// minors 1 and 6). Pure; unit-tested in PairingGuidanceTests. Used by Settings › Sensor, the
// onboarding pairing step, the Now hero and the S5 banners.
//
//   pairingRejected, pairingCodeNeeded → pair again: the worn sensor's 4-digit code, sent with
//                                        G7Kit's `pairAgain(code:)` (not the new-sensor flow)
//   bondRemoved                        → forget the sensor in iOS Bluetooth first, then pair again
//   bluetoothPairingIncomplete         → nothing to type: accept the iOS pairing request at the next
//                                        sensor connection
//   sensor replacement kinds           → pair a new sensor (the normal new-sensor flow)
//   credentialsUnavailable             → the app retries after unlock; "pair again" is offered in
//                                        Settings only if it persists (`credentialsRetryWindow`)

import Foundation
import GlucoseCore

enum PairingRecovery: Equatable, Sendable {
    /// Re-pair the sensor being worn: follow `steps`, then enter its code (`pairAgain(code:)`).
    case pairAgain(steps: [String])
    /// No code entry: the pairing completes when the person accepts the iOS Bluetooth prompt.
    case acceptBluetoothPrompt(instruction: String)
    /// This sensor can't be used any more: pair a new one (new-sensor flow).
    case pairNewSensor(instruction: String)
    /// During first pairing, anything else: show the message and let the person try the code again.
    case retryCode
}

enum PairingGuidance {
    static let enterCode = "Enter the 4-digit pairing code from the applicator of the sensor you're wearing."
    static let forgetInBluetooth = "First forget the sensor in iOS Settings › Bluetooth: tap ⓘ next to it, then Forget This Device."
    static let acceptPrompt = "Accept the Bluetooth pairing request when it appears at the next sensor connection (within about 5 minutes)."
    static let newSensor = "This sensor can't be used. Apply a new sensor and enter its pairing code."

    /// How long `credentialsUnavailable` must last before Settings offers "Pair again". The app
    /// retries by itself once the phone is unlocked, so a short spell needs no action.
    static let credentialsRetryWindow: TimeInterval = 15 * 60

    static func recovery(for failure: SensorFailure) -> PairingRecovery {
        if failure.requiresSensorReplacement { return .pairNewSensor(instruction: newSensor) }
        switch failure.kind {
        case .bondRemoved: return .pairAgain(steps: [forgetInBluetooth, enterCode])
        case .pairingRejected, .pairingCodeNeeded: return .pairAgain(steps: [enterCode])
        case .bluetoothPairingIncomplete: return .acceptBluetoothPrompt(instruction: acceptPrompt)
        default: return .retryCode
        }
    }

    /// What Settings › Sensor offers for the current state.
    /// - Parameter failureSince: when the current failure started (Phase 2 fills it), for the
    ///   `credentialsUnavailable` persistence rule.
    static func settingsOffer(for state: SensorState, failureSince: Date?, now: Date) -> PairingRecovery? {
        switch state {
        case .notPaired, .expired:
            return .pairNewSensor(instruction: "Apply a sensor and enter its 4-digit pairing code.")
        case .failed(let failure):
            if failure.kind == .credentialsUnavailable {
                guard let failureSince, now.timeIntervalSince(failureSince) >= credentialsRetryWindow else { return nil }
                return .pairAgain(steps: [enterCode])
            }
            switch recovery(for: failure) {
            case .retryCode: return nil // transient: nothing to do but wait (banner explains)
            case let offer: return offer
            }
        default:
            return nil
        }
    }

    /// Banner/hero text for a lost pairing: the source's message plus, for a removed bond, the
    /// step iOS needs first.
    static func pairAgainDetail(_ failure: SensorFailure) -> String {
        failure.kind == .bondRemoved ? "\(failure.message) \(forgetInBluetooth)" : failure.message
    }
}
