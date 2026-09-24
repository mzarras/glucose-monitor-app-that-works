import GlucoseCore
import XCTest
@testable import Sensor

/// D36/D37 review M1, minors 1 and 6: every pairing-related failure leads somewhere sensible.
final class PairingGuidanceTests: XCTestCase {
    private func failure(_ kind: SensorFailure.Kind) -> SensorFailure {
        SensorFailure(kind: kind, message: "Message for \(kind)")
    }

    func test_recoveryForEachKind() {
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.pairingRejected)), .pairAgain(steps: [PairingGuidance.enterCode]))
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.pairingCodeNeeded)), .pairAgain(steps: [PairingGuidance.enterCode]))
        // Removed bond: forget the sensor in iOS Bluetooth first, then the code.
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.bondRemoved)), .pairAgain(steps: [PairingGuidance.forgetInBluetooth, PairingGuidance.enterCode]))
        // Nothing to type: accept the iOS request at the next connection.
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.bluetoothPairingIncomplete)), .acceptBluetoothPrompt(instruction: PairingGuidance.acceptPrompt))
        XCTAssertTrue(PairingGuidance.acceptPrompt.contains("within about 5 minutes"))
        // An unusable sensor offers a new one — never a dead end (minor 6).
        for kind in [SensorFailure.Kind.sensorFailed, .sessionStopped, .unsupportedSensor] {
            XCTAssertEqual(PairingGuidance.recovery(for: failure(kind)), .pairNewSensor(instruction: PairingGuidance.newSensor), "\(kind)")
        }
        // Every kind maps to something.
        for kind in SensorFailure.Kind.allCases {
            _ = PairingGuidance.recovery(for: failure(kind))
        }
        XCTAssertEqual(PairingGuidance.recovery(for: failure(.otherAppRejected)), .retryCode)
    }

    func test_settingsOffersPairAgainOnlyForLostPairingOrPersistentCredentials() {
        let now = t0
        XCTAssertEqual(PairingGuidance.settingsOffer(for: .failed(failure(.pairingRejected)), failureSince: nil, now: now),
                       .pairAgain(steps: [PairingGuidance.enterCode]))
        XCTAssertEqual(PairingGuidance.settingsOffer(for: .failed(failure(.bondRemoved)), failureSince: nil, now: now),
                       .pairAgain(steps: [PairingGuidance.forgetInBluetooth, PairingGuidance.enterCode]))
        // Minor 1: credentials unavailable — the app retries after unlock; offer only if it persists.
        let credentials = SensorState.failed(failure(.credentialsUnavailable))
        XCTAssertNil(PairingGuidance.settingsOffer(for: credentials, failureSince: nil, now: now))
        XCTAssertNil(PairingGuidance.settingsOffer(for: credentials, failureSince: minutes(-14.9), now: now))
        XCTAssertEqual(PairingGuidance.settingsOffer(for: credentials, failureSince: minutes(-15), now: now), .pairAgain(steps: [PairingGuidance.enterCode]))
        // Transient kinds: nothing to do in Settings (the banner explains).
        XCTAssertNil(PairingGuidance.settingsOffer(for: .failed(failure(.otherAppRejected)), failureSince: minutes(-60), now: now))
        XCTAssertEqual(PairingGuidance.settingsOffer(for: .failed(failure(.bluetoothPairingIncomplete)), failureSince: nil, now: now),
                       .acceptBluetoothPrompt(instruction: PairingGuidance.acceptPrompt))
        // New-sensor flow for no sensor, an expired one, or an unusable one.
        XCTAssertEqual(PairingGuidance.settingsOffer(for: .failed(failure(.unsupportedSensor)), failureSince: nil, now: now),
                       .pairNewSensor(instruction: PairingGuidance.newSensor))
        if case .pairNewSensor = PairingGuidance.settingsOffer(for: .notPaired, failureSince: nil, now: now) {} else { XCTFail("not paired") }
        if case .pairNewSensor = PairingGuidance.settingsOffer(for: .expired, failureSince: nil, now: now) {} else { XCTFail("expired") }
        XCTAssertNil(PairingGuidance.settingsOffer(for: activeSensor, failureSince: nil, now: now))
    }

    func test_pairAgainDetailAddsTheBluetoothStepForARemovedBond() {
        XCTAssertEqual(PairingGuidance.pairAgainDetail(failure(.pairingRejected)), "Message for pairingRejected")
        XCTAssertTrue(PairingGuidance.pairAgainDetail(failure(.bondRemoved)).hasSuffix(PairingGuidance.forgetInBluetooth))
    }
}
