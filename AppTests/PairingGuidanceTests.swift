import GlucoseCore
import XCTest
@testable import Sensor

/// D36/D37 reviews M1, N1, N2, minors 1 and 6: every pairing-related failure leads somewhere that
/// works, and every code entry names the G7Kit call it makes.
final class PairingGuidanceTests: XCTestCase {
    private func failure(_ kind: SensorFailure.Kind) -> SensorFailure {
        SensorFailure(kind: kind, message: "Message for \(kind)")
    }

    private let authenticatedNewPairing = PairingContext(hasStoredSensor: true, isNewPairing: true, authenticatedInThisPairing: true)

    // MARK: Review N2

    /// A wrong code in a new pairing has no stored sensor: `pairAgain(code:)` would throw
    /// `.noSensorToPairAgain`. The offer must be another try with `pair(code:)` and new-sensor copy.
    func test_S5_newPairingTypoOffersRetryNotPairAgain() {
        for kind in [SensorFailure.Kind.pairingRejected, .pairingCodeNeeded] {
            XCTAssertEqual(PairingGuidance.recovery(for: failure(kind), context: .newPairing),
                           .enterCode(steps: [PairingGuidance.checkNewCode], buttonTitle: "Try again", action: .pair), "\(kind)")
            // Even if an older sensor's record is still stored (replacing a sensor): still a new pairing.
            let replacing = PairingContext(hasStoredSensor: true, isNewPairing: true, authenticatedInThisPairing: false)
            XCTAssertEqual(PairingGuidance.recovery(for: failure(kind), context: replacing),
                           .enterCode(steps: [PairingGuidance.checkNewCode], buttonTitle: "Try again", action: .pair), "\(kind), replacing")
        }
        XCTAssertFalse(PairingGuidance.checkNewCode.contains("wearing"), "no 'the sensor you're wearing' copy in a new pairing")
        // No offer in a new pairing ever routes to pairAgain unless this pairing authenticated.
        for kind in SensorFailure.Kind.allCases {
            if case .enterCode(_, _, let action) = PairingGuidance.recovery(for: failure(kind), context: .newPairing) {
                XCTAssertEqual(action, .pair, "\(kind)")
            }
        }
    }

    /// Review N1 item 3: once this onboarding pairing has authenticated, the sensor is stored and a
    /// retry goes to `pairAgain(code:)`.
    func test_retryAfterAuthenticationInOnboardingUsesPairAgain() {
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.pairingRejected), context: authenticatedNewPairing),
                       .enterCode(steps: [PairingGuidance.enterWornCode], buttonTitle: "Pair again", action: .pairAgain))
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.otherAppRejected), context: authenticatedNewPairing),
                       .enterCode(steps: [], buttonTitle: "Pair again", action: .pairAgain))
    }

    // MARK: Review M1 (lost pairing of the worn sensor)

    func test_lostPairingWithAStoredSensorUsesPairAgain() {
        let stored = PairingContext.existing(hasStoredSensor: true)
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.pairingRejected), context: stored),
                       .enterCode(steps: [PairingGuidance.enterWornCode], buttonTitle: "Pair again", action: .pairAgain))
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.pairingCodeNeeded), context: stored),
                       .enterCode(steps: [PairingGuidance.enterWornCode], buttonTitle: "Pair again", action: .pairAgain))
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.bondRemoved), context: stored),
                       .enterCode(steps: [PairingGuidance.forgetInBluetooth, PairingGuidance.enterWornCode], buttonTitle: "Pair again", action: .pairAgain))
    }

    func test_lostPairingWithoutAStoredSensorUsesPair() {
        let none = PairingContext.existing(hasStoredSensor: false)
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.pairingRejected), context: none),
                       .enterCode(steps: [PairingGuidance.enterNewCode], buttonTitle: "Try again", action: .pair))
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.bondRemoved), context: none),
                       .enterCode(steps: [PairingGuidance.forgetInBluetooth, PairingGuidance.enterNewCode], buttonTitle: "Pair sensor", action: .pair))
    }

    func test_incompleteBluetoothPairingHasNoCodeEntry() {
        for context in [PairingContext.newPairing, .existing(hasStoredSensor: true), authenticatedNewPairing] {
            XCTAssertEqual(PairingGuidance.recovery(for: failure(.bluetoothPairingIncomplete), context: context),
                           .acceptBluetoothPrompt(instruction: PairingGuidance.acceptPrompt))
        }
        XCTAssertTrue(PairingGuidance.acceptPrompt.contains("within about 5 minutes"))
    }

    /// Minor 6: an unusable sensor offers a new one (never a dead end), always with `pair(code:)`.
    func test_unusableSensorOffersANewOne() {
        for kind in [SensorFailure.Kind.sensorFailed, .sessionStopped, .unsupportedSensor] {
            for context in [PairingContext.newPairing, .existing(hasStoredSensor: true)] {
                XCTAssertEqual(PairingGuidance.recovery(for: failure(kind), context: context),
                               .enterCode(steps: [PairingGuidance.newSensor], buttonTitle: "Pair a new sensor", action: .pair), "\(kind)")
            }
        }
    }

    // MARK: Settings, including minor 1

    func test_settingsOffers() {
        let now = t0
        XCTAssertEqual(PairingGuidance.settingsOffer(for: .failed(failure(.pairingRejected)), failureSince: nil, hasStoredSensor: true, now: now),
                       .enterCode(steps: [PairingGuidance.enterWornCode], buttonTitle: "Pair again", action: .pairAgain))
        XCTAssertEqual(PairingGuidance.settingsOffer(for: .failed(failure(.pairingRejected)), failureSince: nil, hasStoredSensor: false, now: now),
                       .enterCode(steps: [PairingGuidance.enterNewCode], buttonTitle: "Try again", action: .pair))
        XCTAssertNil(PairingGuidance.settingsOffer(for: .failed(failure(.otherAppRejected)), failureSince: minutes(-60), hasStoredSensor: true, now: now),
                     "transient: nothing to do but wait")
        XCTAssertEqual(PairingGuidance.settingsOffer(for: .failed(failure(.bluetoothPairingIncomplete)), failureSince: nil, hasStoredSensor: true, now: now),
                       .acceptBluetoothPrompt(instruction: PairingGuidance.acceptPrompt))
        for state in [SensorState.notPaired, .expired] {
            guard case .enterCode(_, _, let action)? = PairingGuidance.settingsOffer(for: state, failureSince: nil, hasStoredSensor: false, now: now) else {
                return XCTFail("\(state): no new-sensor offer")
            }
            XCTAssertEqual(action, .pair)
        }
        XCTAssertNil(PairingGuidance.settingsOffer(for: activeSensor, failureSince: nil, hasStoredSensor: true, now: now))
    }

    /// Minor 1: after 15 min of unreadable credentials, "Pair again" sends the worn sensor's code to
    /// `pair(code:)` (which tolerates the unreadable record), never `pairAgain(code:)`.
    func test_persistentCredentialsProblemUsesPairNotPairAgain() {
        let credentials = SensorState.failed(failure(.credentialsUnavailable))
        XCTAssertNil(PairingGuidance.settingsOffer(for: credentials, failureSince: nil, hasStoredSensor: true, now: t0))
        XCTAssertNil(PairingGuidance.settingsOffer(for: credentials, failureSince: minutes(-14.9), hasStoredSensor: true, now: t0))
        XCTAssertEqual(PairingGuidance.settingsOffer(for: credentials, failureSince: minutes(-15), hasStoredSensor: true, now: t0),
                       .enterCode(steps: [PairingGuidance.enterWornCode], buttonTitle: "Pair again", action: .pair))
    }

    func test_pairAgainDetailAddsTheBluetoothStepForARemovedBond() {
        XCTAssertEqual(PairingGuidance.pairAgainDetail(failure(.pairingRejected)), "Message for pairingRejected")
        XCTAssertTrue(PairingGuidance.pairAgainDetail(failure(.bondRemoved)).hasSuffix(PairingGuidance.forgetInBluetooth))
    }
}
