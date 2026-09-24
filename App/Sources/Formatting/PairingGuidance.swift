// What the UI offers the person for each pairing-related sensor failure (D36/D37 reviews M1, N1,
// N2, minors 1 and 6). Pure; unit-tested in PairingGuidanceTests. Used by Settings › Sensor, the
// onboarding pairing step, the Now hero and the S5 banners.
//
// Every offer that asks for a code says which G7Kit call the code goes to:
//   `.pair`      — `pair(code:)`: pairs the sensor as new; always possible, tolerates an
//                  unreadable stored record.
//   `.pairAgain` — `pairAgain(code:)`: re-pairs the *stored* sensor; throws `.noSensorToPairAgain`
//                  when there is none, so it is offered only when a sensor is stored and we are
//                  not in a new pairing (unless this very pairing already authenticated).
//
//   new pairing, wrong/missing code         → try the code again with `pair(code:)` (new-sensor copy)
//   new pairing that already authenticated  → `pairAgain(code:)` (the sensor is stored now)
//   lost pairing with a stored sensor       → `pairAgain(code:)`; bondRemoved: forget it in iOS first
//   lost pairing, no stored sensor          → `pair(code:)`
//   bluetoothPairingIncomplete              → nothing to type: accept the iOS pairing request
//   sensor replacement kinds                → pair a new sensor, `pair(code:)`
//   credentialsUnavailable, persisting      → the worn sensor's code with `pair(code:)` (Settings)

import Foundation
import GlucoseCore

/// Which G7Kit call a code entry makes.
enum PairingCodeAction: Equatable, Sendable {
    case pair
    case pairAgain
}

enum PairingRecovery: Equatable, Sendable {
    /// Follow `steps`, then enter a 4-digit code, sent with `action`.
    case enterCode(steps: [String], buttonTitle: String, action: PairingCodeAction)
    /// No code entry: the pairing completes when the person accepts the iOS Bluetooth prompt.
    case acceptBluetoothPrompt(instruction: String)
}

/// Facts the UI needs to choose between `pair(code:)` and `pairAgain(code:)` (review N2).
struct PairingContext: Equatable, Sendable {
    /// G7Kit `hasStoredSensor`: a sensor's pairing record is stored on this phone.
    var hasStoredSensor: Bool
    /// The onboarding new-pairing flow (first sensor, or replacing one).
    var isNewPairing: Bool
    /// This new pairing already authenticated with the sensor (review N1 item 3); the sensor is
    /// stored from then on, so a retry goes to `pairAgain(code:)`.
    var authenticatedInThisPairing: Bool

    /// Onboarding before the sensor has authenticated.
    static let newPairing = PairingContext(hasStoredSensor: false, isNewPairing: true, authenticatedInThisPairing: false)

    /// Settings: not a new pairing.
    static func existing(hasStoredSensor: Bool) -> PairingContext {
        PairingContext(hasStoredSensor: hasStoredSensor, isNewPairing: false, authenticatedInThisPairing: false)
    }

    /// Whether `pairAgain(code:)` has a sensor to re-pair.
    var canPairAgain: Bool {
        isNewPairing ? authenticatedInThisPairing : hasStoredSensor
    }
}

enum PairingGuidance {
    static let enterWornCode = "Enter the 4-digit pairing code from the applicator of the sensor you're wearing."
    static let checkNewCode = "Check the 4-digit pairing code on the new sensor's applicator and enter it again."
    static let enterNewCode = "Enter the 4-digit pairing code from the sensor's applicator."
    static let forgetInBluetooth = "First forget the sensor in iOS Settings › Bluetooth: tap ⓘ next to it, then Forget This Device."
    static let acceptPrompt = "Accept the Bluetooth pairing request when it appears at the next sensor connection (within about 5 minutes)."
    static let newSensor = "This sensor can't be used. Apply a new sensor and enter its pairing code."

    /// How long `credentialsUnavailable` must last before Settings offers to pair again. The app
    /// retries by itself once the phone is unlocked, so a short spell needs no action.
    static let credentialsRetryWindow: TimeInterval = 15 * 60

    static func recovery(for failure: SensorFailure, context: PairingContext) -> PairingRecovery {
        if failure.requiresSensorReplacement {
            return .enterCode(steps: [newSensor], buttonTitle: "Pair a new sensor", action: .pair)
        }
        switch failure.kind {
        case .bluetoothPairingIncomplete:
            return .acceptBluetoothPrompt(instruction: acceptPrompt)
        case .bondRemoved:
            return context.canPairAgain
                ? .enterCode(steps: [forgetInBluetooth, enterWornCode], buttonTitle: "Pair again", action: .pairAgain)
                : .enterCode(steps: [forgetInBluetooth, enterNewCode], buttonTitle: "Pair sensor", action: .pair)
        case .pairingRejected, .pairingCodeNeeded:
            if context.canPairAgain {
                return .enterCode(steps: [enterWornCode], buttonTitle: "Pair again", action: .pairAgain)
            }
            // A typo in a new pairing (G7Kit reports it with no stored sensor): try again (N2).
            return .enterCode(steps: [context.isNewPairing ? checkNewCode : enterNewCode], buttonTitle: "Try again", action: .pair)
        default:
            // Anything else during a pairing: show the message and allow another try.
            return .enterCode(steps: [], buttonTitle: context.canPairAgain ? "Pair again" : "Try again",
                              action: context.canPairAgain ? .pairAgain : .pair)
        }
    }

    /// What Settings › Sensor offers for the current state (never a new pairing).
    /// - Parameters:
    ///   - failureSince: when the current failure started, for the `credentialsUnavailable`
    ///     persistence rule.
    ///   - hasStoredSensor: G7Kit `hasStoredSensor`.
    static func settingsOffer(for state: SensorState, failureSince: Date?, hasStoredSensor: Bool, now: Date) -> PairingRecovery? {
        switch state {
        case .notPaired, .expired:
            return .enterCode(steps: ["Apply a sensor.", enterNewCode], buttonTitle: "Pair a new sensor", action: .pair)
        case .failed(let failure):
            if failure.kind == .credentialsUnavailable {
                // Minor 1: `pair(code:)` with the worn sensor's code — it tolerates the unreadable
                // record, whereas `pairAgain(code:)` would re-read the Keychain and fail again.
                guard let failureSince, now.timeIntervalSince(failureSince) >= credentialsRetryWindow else { return nil }
                return .enterCode(steps: [enterWornCode], buttonTitle: "Pair again", action: .pair)
            }
            guard failure.requiresPairing || failure.requiresSensorReplacement || failure.kind == .bluetoothPairingIncomplete else {
                return nil // transient: nothing to do but wait (the banner explains)
            }
            return recovery(for: failure, context: .existing(hasStoredSensor: hasStoredSensor))
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
