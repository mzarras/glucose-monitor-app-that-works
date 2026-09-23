// Original to Sensor (no ported code). Captured vectors are cited where they are used.

import XCTest
@testable import G7Kit

final class G7AuthMessageTests: XCTestCase {
    /// `02 || token(8) || slot` (DexcomG7AuthBridge.m:203-218).
    func test_authRequestLayout() {
        let token: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(G7AuthRequest.make(token: token, slot: .mobileApp), Data([0x02, 1, 2, 3, 4, 5, 6, 7, 8, 0x02]))
        XCTAssertEqual(G7AuthRequest.make(token: token, slot: .receiverOrPump).last, 0x01)
        XCTAssertEqual(G7AuthRequest.make(token: token, slot: .smartWatch).last, 0x03)
    }

    /// `03 || tokenHash(8) || challenge(8)` (AuthRequestRxMessage.swift:16-27).
    func test_challengeMessage() throws {
        let message = try XCTUnwrap(G7AuthChallengeMessage(Data(hex: "03 1111111111111111 2222222222222222")))
        XCTAssertEqual(message.tokenHash, [UInt8](repeating: 0x11, count: 8))
        XCTAssertEqual(message.challenge, [UInt8](repeating: 0x22, count: 8))
        XCTAssertNil(G7AuthChallengeMessage(Data(hex: "03 1111111111111111 22222222222222")), "16 bytes")
        XCTAssertNil(G7AuthChallengeMessage(Data(hex: "05 1111111111111111 2222222222222222")), "opcode")
        XCTAssertEqual(G7AuthChallengeResponse.make(hash: [9, 9, 9, 9, 9, 9, 9, 9]), Data([0x04, 9, 9, 9, 9, 9, 9, 9, 9]))
    }

    /// `05 authenticated paired` (AuthChallengeRxMessage.swift:25-26: paired = byte2 != 2).
    func test_authStatus() throws {
        let both = try XCTUnwrap(G7AuthStatusMessage(Data([0x05, 0x01, 0x01])))
        XCTAssertTrue(both.authenticated)
        XCTAssertTrue(both.paired)
        let unpaired = try XCTUnwrap(G7AuthStatusMessage(Data([0x05, 0x01, 0x02])))
        XCTAssertTrue(unpaired.authenticated)
        XCTAssertFalse(unpaired.paired)
        let rejected = try XCTUnwrap(G7AuthStatusMessage(Data([0x05, 0x02, 0x02])))
        XCTAssertFalse(rejected.authenticated)
        XCTAssertNil(G7AuthStatusMessage(Data([0x05, 0x01])))
        XCTAssertNil(G7AuthStatusMessage(Data([0x06, 0x01, 0x01])))
    }
}

final class G7OwnershipMessageTests: XCTestCase {
    func test_pakeControlAndStatus() throws {
        XCTAssertEqual(G7PakeControl.request(phase: 0), Data([0x0A, 0x00]))
        XCTAssertEqual(G7PakeControl.request(phase: 2), Data([0x0A, 0x02]))
        XCTAssertEqual(try XCTUnwrap(G7PakeStatus(Data([0x0A, 0x00, 0x01]))).phase, 1)
        XCTAssertNil(G7PakeStatus(Data([0x0A, 0x01, 0x01])), "non-zero status is a rejection")
        XCTAssertNil(G7PakeStatus(Data([0x0A, 0x00])))
        XCTAssertNil(G7PakeStatus(Data([0x0B, 0x00, 0x01])))
    }

    /// Little-endian length (DexcomG7AuthBridge.m:291-295): 0x1EE = 494 bytes for part A.
    func test_certificateControlAndStatus() throws {
        XCTAssertEqual(G7CertificateControl.request(phase: 0, certificateLength: 494), Data([0x0B, 0x00, 0xEE, 0x01, 0x00, 0x00]))
        let status = try XCTUnwrap(G7CertificateStatus(Data([0x0B, 0x00, 0x01, 0x2C, 0x01, 0x00, 0x00])))
        XCTAssertEqual(status.phase, 1)
        XCTAssertEqual(status.size, 300)
        XCTAssertNil(G7CertificateStatus(Data([0x0B, 0x01, 0x01, 0x2C, 0x01, 0x00, 0x00])))
        XCTAssertNil(G7CertificateStatus(Data([0x0B, 0x00, 0x01, 0x2C, 0x01, 0x00])))
        XCTAssertNil(G7CertificateStatus(Data([0x0C, 0x00, 0x01, 0x2C, 0x01, 0x00, 0x00])))
    }

    func test_proofOfPossession() throws {
        let challenge = [UInt8](0..<16)
        XCTAssertEqual(G7ProofControl.challengeRequest(challenge: challenge), Data([0x0C] + challenge))
        XCTAssertEqual(G7ProofControl.signatureSubmitted, Data([0x0D, 0x00, 0x02]))
        XCTAssertEqual(try XCTUnwrap(G7ProofChallenge(Data([0x0C, 0x00] + challenge))).challenge, challenge)
        XCTAssertNil(G7ProofChallenge(Data([0x0C, 0x01] + challenge)))
        XCTAssertNil(G7ProofChallenge(Data([0x0C, 0x00] + challenge + [0x00])), "must be exactly 18 bytes")
        XCTAssertNil(G7ProofChallenge(Data([0x0B, 0x00] + challenge)))
    }

    /// xDrip Tests/DexcomG7CalibrationTests.swift:329-342 (`ownershipKeepAliveAction`).
    func test_keepAliveAndLegacyBond() {
        XCTAssertEqual(G7OwnershipKeepAlive.request, Data([0x06, 0x19]))
        XCTAssertEqual(G7OwnershipKeepAlive.outcome(of: Data([0x06, 0x01])), .complete)
        XCTAssertEqual(G7OwnershipKeepAlive.outcome(of: Data([0x06, 0x00])), .legacyBondRequired)
        XCTAssertEqual(G7OwnershipKeepAlive.outcome(of: Data([0x06, 0x02])), .ignore)
        XCTAssertEqual(G7LegacyBond.request, Data([0x07]))
        XCTAssertTrue(G7LegacyBond.isBondRequestEcho(Data([0x07, 0x00])))
        XCTAssertFalse(G7LegacyBond.isBondRequestEcho(Data([0x07, 0x01])))
        XCTAssertTrue(G7LegacyBond.isPairConfirmation(Data([0x08, 0x01])))
        XCTAssertFalse(G7LegacyBond.isPairConfirmation(Data([0x08, 0x00])))
    }
}

final class G7ControlRequestTests: XCTestCase {
    func test_singleByteRequestsAndBackfillEnd() {
        XCTAssertEqual(G7ControlRequest.glucose, Data([0x4E]))
        XCTAssertEqual(G7ControlRequest.extendedVersion, Data([0x52]))
        XCTAssertEqual(G7ControlRequest.calibrationBounds, Data([0x32]))
        XCTAssertTrue(G7ControlRequest.isBackfillFinished(Data([0x59])))
        XCTAssertFalse(G7ControlRequest.isBackfillFinished(Data([0x4E])))
        XCTAssertFalse(G7ControlRequest.isBackfillFinished(Data()))
    }

    /// xDrip Tests/DexcomG7CalibrationTests.swift:576-581: CRC framing of `4A` and `22`.
    func test_crc16MatchesXDripVectors() {
        XCTAssertEqual(G7CRC16.appending(to: [0x4A]), [0x4A, 0x8E, 0xE9])
        XCTAssertEqual(G7CRC16.appending(to: [0x22]), [0x22, 0x20, 0x04])
        XCTAssertTrue(G7CRC16.isValid([0x4A, 0x8E, 0xE9]))
        XCTAssertFalse(G7CRC16.isValid([0x4A, 0x8E, 0xEA]))
        XCTAssertFalse(G7CRC16.isValid([0x4A, 0x8E]))
        // CRC-16/XMODEM check value for "123456789" is 0x31C3 (standard catalogue value).
        XCTAssertEqual(G7CRC16.checksum(Array("123456789".utf8)), 0x31C3)
    }
}

final class G7CalibrationMessageTests: XCTestCase {
    /// xDrip Tests/DexcomG7CalibrationTests.swift:5-11: 153 mg/dL at sensor time 0x0008840E.
    func test_commandWireFormat() {
        let data = G7CalibrationCommand(glucose: 153, sensorTime: 0x0008_840E).data
        XCTAssertEqual(data.count, 9)
        XCTAssertEqual(data.prefix(7), Data([0x34, 0x99, 0x00, 0x0E, 0x84, 0x08, 0x00]))
        XCTAssertTrue(G7CRC16.isValid([UInt8](data)))
    }

    /// xDrip Tests/DexcomG7CalibrationTests.swift:44-54.
    func test_commandResponses() {
        func status(_ bytes: [UInt8]) -> G7CalibrationCommandStatus? { G7CalibrationCommandResponse(Data(bytes))?.status }
        XCTAssertEqual(status([0x34, 0, 0, 0]), .acceptedHigh(.accepted))
        XCTAssertEqual(status([0x34, 0, 1, 0]), .acceptedLow(.accepted))
        XCTAssertEqual(status([0x34, 0, 0, 1]), .acceptedHigh(.error0))
        XCTAssertEqual(status([0x34, 0, 1, 2]), .acceptedLow(.error1))
        XCTAssertEqual(status([0x34, 0, 0, 7]), .acceptedHigh(.unknown(7)))
        XCTAssertEqual(status([0x34, 0, 2, 3]), .rejected(.duplicate))
        XCTAssertEqual(status([0x34, 0, 2, 6]), .rejected(.alreadyEntered))
        XCTAssertEqual(status([0x34, 0, 2, 8]), .rejected(.notPermitted))
        XCTAssertEqual(status([0x34, 0, 3, 0]), .factoryCalibrated)
        XCTAssertEqual(status([0x34, 0, 9, 7]), .unknown(primary: 9, secondary: 7))
        let response = G7CalibrationCommandResponse(Data([0x34, 0x05, 0x02, 0x01]))
        XCTAssertEqual(response?.transmitterResponse, 0x05)
        XCTAssertEqual(response?.primaryStatus, 0x02)
        XCTAssertEqual(response?.secondaryStatus, 0x01)
    }

    /// xDrip Tests/DexcomG7CalibrationTests.swift:56-65: every documented reason stays distinct.
    func test_everyRejectionReasonIsDistinctAndRoundTrips() {
        let expected: [G7CalibrationRejectionReason] = [
            .unspecified, .outsideRange, .timestampInFuture, .duplicate, .earlierThanSessionStart, .notInOrder,
            .alreadyEntered, .disabled, .notPermitted, .calibrationBoundsFailed, .extremeOutlier, .stale,
        ]
        XCTAssertEqual((0...11).map { G7CalibrationRejectionReason(code: UInt8($0)) }, expected)
        XCTAssertEqual(Set(expected.map(\.humanDescription)).count, expected.count, "descriptions distinct")
        for code in UInt8.min...UInt8.max {
            XCTAssertEqual(G7CalibrationRejectionReason(code: code).code, code)
        }
        XCTAssertEqual(G7CalibrationRejectionReason(code: 99), .unknown(99))
        XCTAssertEqual(G7CalibrationRejectionReason(code: 99).humanDescription, "Rejected (unknown reason 99)")
        XCTAssertTrue(G7CalibrationRejectionReason.duplicate.meansAlreadyProcessing)
        XCTAssertTrue(G7CalibrationRejectionReason.alreadyEntered.meansAlreadyProcessing)
        XCTAssertFalse(G7CalibrationRejectionReason.stale.meansAlreadyProcessing)
    }

    /// xDrip Tests/DexcomG7CalibrationTests.swift:67-72.
    func test_malformedResponsesAreRejected() {
        XCTAssertNil(G7CalibrationCommandResponse(Data([0x34, 0, 0])))
        XCTAssertNil(G7CalibrationCommandResponse(Data([0x35, 0, 0, 0])))
        XCTAssertNil(G7CalibrationBounds(Data(repeating: 0, count: 20)))
        XCTAssertNil(G7CalibrationBounds(Data([0x32])))
    }

    /// Captured bounds progress (xDrip Tests/DexcomG7CalibrationTests.swift:13-34):
    ///     32 | 00 response | 01 session | 74000000 signature 116 | 9900 glucose 153 | 0e840800 time
    ///        | 02 in progress | 01 permitted | 02 phone | a1840800 last update
    func test_capturedBoundsProgress() throws {
        let first = try XCTUnwrap(G7CalibrationBounds(Data(hex: "3200017400000099000e840800020102a1840800")))
        XCTAssertEqual(first.transmitterResponse, 0)
        XCTAssertEqual(first.sessionNumber, 1)
        XCTAssertEqual(first.sessionSignature, 116)
        XCTAssertEqual(first.glucose, 153)
        XCTAssertEqual(first.calibrationTime, 0x0008_840E)
        XCTAssertEqual(first.processingState, .inProgress)
        XCTAssertEqual(first.processingRawValue, 2)
        XCTAssertTrue(first.calibrationsPermitted)
        XCTAssertEqual(first.originatingDisplayRawValue, 2)
        XCTAssertEqual(first.lastProcessingUpdateTime, 0x0008_84A1)
        let third = try XCTUnwrap(G7CalibrationBounds(Data(hex: "3200017400000099000e84080003010250850800")))
        XCTAssertEqual(third.processingState, .completeHigh)
        XCTAssertTrue(third.matches(glucose: 153, sensorTime: 0x0008_840E))
        XCTAssertTrue(third.matches(glucose: 153, sensorTime: 0x0008_8410), "2 s tolerance")
        XCTAssertFalse(third.matches(glucose: 152, sensorTime: 0x0008_840E))
        XCTAssertFalse(third.matches(glucose: 153, sensorTime: 0x0008_8420))
        let unknownState = try XCTUnwrap(G7CalibrationBounds(Data(hex: "3200017400000099000e84080009000250850800")))
        XCTAssertNil(unknownState.processingState)
        XCTAssertFalse(unknownState.calibrationsPermitted)
    }

    /// xDrip Tests/DexcomG7CalibrationTests.swift:36-42: a stale record for the previous calibration.
    func test_previousRecordDoesNotMatchInFlightCalibration() throws {
        let previous = try XCTUnwrap(G7CalibrationBounds(Data(hex: "3200015d0000006b00aaca0000030102ebcb0000")))
        let inFlight = try XCTUnwrap(G7CalibrationBounds(Data(hex: "3200015d0000006e0015df00000201024fe00000")))
        XCTAssertFalse(previous.matches(glucose: 110, sensorTime: 57109))
        XCTAssertTrue(inFlight.matches(glucose: 110, sensorTime: 57109))
    }
}
