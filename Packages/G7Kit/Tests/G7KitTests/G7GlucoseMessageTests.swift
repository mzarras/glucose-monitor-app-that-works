// Original to Sensor (no ported code). Captured vectors are cited where they are used.

import GlucoseCore
import XCTest
@testable import G7Kit

final class G7GlucoseMessageTests: XCTestCase {
    /// Captured by LoopKit (G7SensorKitTests/G7GlucoseMessageTests.swift:89-107), annotated with the
    /// Dexcom app's own log line "readEGV(txTime=40104,seq=136,session=1,age=4,value=141,pred=138,algo=6,rate=3)".
    ///     4e | 00 | a89c0000 clock 40104 | 8800 seq 136 | 00 | 01 | 0400 age 4 | 8d00 glucose 141
    ///        | 06 OK | 03 trend +0.3 | 8a00 predicted 138 | 0f flags
    func test_parsesCapturedEGV() throws {
        let message = try XCTUnwrap(G7GlucoseMessage(Data(hex: "4e00a89c00008800000104008d0006038a000f")))
        XCTAssertEqual(message.responseStatus, 0)
        XCTAssertEqual(message.sensorClock, 40104)
        XCTAssertEqual(message.sequence, 136)
        XCTAssertEqual(message.age, 4)
        XCTAssertEqual(message.glucoseRaw, 141)
        XCTAssertEqual(message.algorithmState, .ok)
        XCTAssertEqual(message.trendRate, 0.3)
        XCTAssertEqual(message.predictedRaw, 138)
        XCTAssertFalse(message.isDisplayOnly)
        XCTAssertEqual(message.readingSensorTimestamp, 40100, "sensor clock − age (G7SensorKit :93)")
    }

    /// Two-byte age (G7SensorKitTests/G7GlucoseMessageTests.swift:120-126): clock 154105, age 298.
    func test_twoByteAgeGivesReadingTimestamp() throws {
        let message = try XCTUnwrap(G7GlucoseMessage(Data(hex: "4e00f9590200030200012a018f000610d9000f")))
        XCTAssertEqual(message.age, 298)
        XCTAssertEqual(message.sensorClock, 154105)
        XCTAssertEqual(message.readingSensorTimestamp, 153807)
        XCTAssertEqual(message.glucoseRaw, 143)
        XCTAssertEqual(message.trendRate, 1.6)
    }

    /// Startup lifecycle (G7SensorKitTests/G7GlucoseMessageTests.swift:40-77): stopped, warm-up with
    /// and without values, OK, then expired (0x18) seven hours after the end.
    func test_startupLifecycleVectors() throws {
        let vectors: [(hex: String, glucose: UInt16?, state: UInt8, readingTime: UInt32)] = [
            ("4e00b6000000010000006600ffff017fffff00", nil, 0x01, 80),
            ("4e00cd000000030000010500ffff027fffff01", nil, 0x02, 200),
            ("4e00f90100000400000105009100027effff02", 145, 0x02, 500),
            ("4e00250300000500000105007d00027effff02", 125, 0x02, 800),
            ("4e0051040000060000010500650002dfffff02", 101, 0x02, 1100),
            ("4e007d0500000700000105004e0002e7ffff02", 78, 0x02, 1400),
            ("4e00ab060000080000010700540006f5ffff0e", 84, 0x06, 1700),
            ("4e00d507000009000001050061000601ffff0e", 97, 0x06, 2000),
            ("4e004d440e00d40b0001d46b650018036a000e", 101, 0x18, 907385),
        ]
        for vector in vectors {
            let message = try XCTUnwrap(G7GlucoseMessage(Data(hex: vector.hex)), vector.hex)
            XCTAssertEqual(message.glucoseRaw, vector.glucose, vector.hex)
            XCTAssertEqual(message.algorithmState.rawValue, vector.state, vector.hex)
            XCTAssertEqual(message.readingSensorTimestamp, vector.readingTime, vector.hex)
        }
    }

    /// Display-only after a calibration (G7SensorKitTests/G7GlucoseMessageTests.swift:24-31): flags 0x1f.
    func test_displayOnlyFlag() throws {
        let message = try XCTUnwrap(G7GlucoseMessage(Data(hex: "4e000ec10d00c00b00010000680006fe63001f")))
        XCTAssertTrue(message.isDisplayOnly)
        XCTAssertEqual(message.glucoseRaw, 104)
        XCTAssertEqual(message.trendRate, -0.2)
    }

    /// xDrip4iOS status-0x80 frame (xDrip Tests/DexcomG7CalibrationTests.swift:373-382): a failed
    /// sensor returns its last cached value with state 0x1B.
    func test_nonZeroStatusFrameStillParses() throws {
        let message = try XCTUnwrap(G7GlucoseMessage(Data(hex: "4e80a26b0200e8010001793990001b04ab0000")))
        XCTAssertEqual(message.responseStatus, 0x80)
        XCTAssertEqual(message.sensorClock, 158_626)
        XCTAssertEqual(message.glucoseRaw, 144)
        XCTAssertEqual(message.algorithmState.rawValue, 0x1B)
        XCTAssertEqual(message.algorithmState.category, .sensorFailed)
    }

    func test_missingTrendAndMalformedPackets() throws {
        // Trend 0x7F = none (G7SensorKitTests/G7GlucoseMessageTests.swift:115-118).
        XCTAssertNil(try XCTUnwrap(G7GlucoseMessage(Data(hex: "4e00c6cc0d00ca0b000105006100067f5b000f"))).trendRate)
        XCTAssertNil(G7GlucoseMessage(Data(hex: "4e00c6cc0d00ca0b000105006100067f5b00")), "18 bytes")
        XCTAssertNil(G7GlucoseMessage(Data(hex: "4f00c6cc0d00ca0b000105006100067f5b000f")), "wrong opcode")
        XCTAssertNil(G7GlucoseMessage(Data()))
    }

    func test_ageLargerThanClockHasNoReadingTime() throws {
        let message = try XCTUnwrap(G7GlucoseMessage(Fixture.glucose(sensorClock: 10, age: 11, glucose: 100, state: 0x06)))
        XCTAssertNil(message.readingSensorTimestamp)
    }

    func test_valueSentinelIsNotDisplayOnly() throws {
        let message = try XCTUnwrap(G7GlucoseMessage(Fixture.glucose(sensorClock: 500, age: 5, glucose: nil, state: 0x02, flags: 0x1F)))
        XCTAssertNil(message.glucoseRaw)
        XCTAssertFalse(message.isDisplayOnly)
    }

    /// The upper 4 bits of the glucose field are flags; only the low 12 bits are the value.
    func test_glucoseIsMaskedTo12Bits() throws {
        let message = try XCTUnwrap(G7GlucoseMessage(Fixture.glucose(sensorClock: 5000, age: 3, glucose: 0x8078, state: 0x06, predicted: 0x9064)))
        XCTAssertEqual(message.glucoseRaw, 0x078)
        XCTAssertEqual(message.predictedRaw, 0x064)
    }
}

final class G7BackfillMessageTests: XCTestCase {
    /// The backfill copy of the two-byte-age reading (G7SensorKitTests/G7GlucoseMessageTests.swift:143-151).
    ///     cf5802 timestamp 153807 | 00 | 8f00 glucose 143 | 06 OK | 0f flags | 10 trend +1.6
    func test_parsesCapturedRecord() throws {
        let record = try XCTUnwrap(G7BackfillMessage(Data(hex: "cf5802008f00060f10")))
        XCTAssertEqual(record.sensorTimestamp, 153807)
        XCTAssertEqual(record.glucoseRaw, 143)
        XCTAssertEqual(record.algorithmState, .ok)
        XCTAssertEqual(record.trendRate, 1.6)
        XCTAssertFalse(record.isDisplayOnly)
    }

    /// Timestamp with a high byte (G7SensorKitTests/G7GlucoseMessageTests.swift:153-157) and
    /// xDrip4iOS's own layout comment `45a100 00 9600 06 0f fc` (DexcomG7BackfillMessage.swift:15-17).
    func test_timestampBytes() throws {
        XCTAssertEqual(try XCTUnwrap(G7BackfillMessage(Data(hex: "f20e0d00ba00060ffb"))).sensorTimestamp, 855794)
        let xdrip = try XCTUnwrap(G7BackfillMessage(Data(hex: "45a10000960006 0ffc")))
        XCTAssertEqual(xdrip.sensorTimestamp, 0xA145)
        XCTAssertEqual(xdrip.glucoseRaw, 150)
        XCTAssertEqual(xdrip.trendRate, -0.4)
    }

    /// Calibration record: byte 7 = 0x1e has bit 0x10 (G7SensorKitTests/G7GlucoseMessageTests.swift:159-165).
    func test_displayOnlyFromFlagsByteOrGlucoseNibble() throws {
        XCTAssertTrue(try XCTUnwrap(G7BackfillMessage(Data(hex: "f63d00008500061efe"))).isDisplayOnly)
        XCTAssertTrue(try XCTUnwrap(G7BackfillMessage(Fixture.backfill(timestamp: 900, glucose: 0x1085, flags: 0x0F))).isDisplayOnly,
                      "xDrip4iOS reads display-only from the glucose high nibble (DexcomG7BackfillMessage.swift:31)")
    }

    func test_sentinelsAndMalformed() throws {
        let record = try XCTUnwrap(G7BackfillMessage(Fixture.backfill(timestamp: 300, glucose: nil, state: 0x02)))
        XCTAssertNil(record.glucoseRaw)
        XCTAssertNil(record.trendRate)
        XCTAssertFalse(record.isDisplayOnly)
        XCTAssertNil(G7BackfillMessage(Data(hex: "cf5802008f00060f")), "8 bytes")
        XCTAssertNil(G7BackfillMessage(Data(hex: "cf5802008f00060f1000")), "10 bytes")
    }
}

final class G7ExtendedVersionMessageTests: XCTestCase {
    /// xDrip Tests/DexcomG7CalibrationTests.swift:231-249 (same vectors as G7SensorKit's).
    func test_tenAndFifteenDayVectors() throws {
        let ten = try XCTUnwrap(G7ExtendedVersionMessage(Fixture.tenDayExtendedVersion))
        XCTAssertEqual(ten.sessionLength, 10.5 * 86_400)
        XCTAssertEqual(ten.warmUpDuration, 27 * 60)
        XCTAssertEqual(ten.algorithmVersion, 67_371_520)
        XCTAssertEqual(ten.hardwareVersion, 255)
        XCTAssertEqual(ten.maxLifetimeDays, 12)
        let fifteen = try XCTUnwrap(G7ExtendedVersionMessage(Fixture.fifteenDayExtendedVersion))
        XCTAssertEqual(fifteen.sessionLength, 15.5 * 86_400)
        XCTAssertEqual(fifteen.warmUpDuration, 62 * 60)
    }

    /// xDrip Tests/DexcomG7CalibrationTests.swift:251-254.
    func test_rejectsWrongOpcodeAndTruncated() {
        XCTAssertNil(G7ExtendedVersionMessage(Data([0x53] + Array(repeating: 0, count: 14))))
        XCTAssertNil(G7ExtendedVersionMessage(Data([0x52] + Array(repeating: 0, count: 13))))
        XCTAssertNotNil(G7ExtendedVersionMessage(Fixture.tenDayExtendedVersion + Data([0xAA])), "longer is accepted")
    }
}

final class G7AlgorithmStateTests: XCTestCase {
    func test_onlyOxO6IsOK() {
        for raw in UInt8.min...UInt8.max {
            let state = G7AlgorithmState(rawValue: raw)
            XCTAssertEqual(state.category == .ok, raw == 0x06, "0x\(String(raw, radix: 16))")
            XCTAssertFalse(state.name.isEmpty)
        }
    }

    func test_categoriesFromTable() {
        let expectations: [(UInt8, G7AlgorithmState.Category)] = [
            (0x00, .unknown), (0x01, .stopped), (0x02, .warmUp), (0x03, .temporaryIssue), (0x04, .calibrationNeeded),
            (0x05, .calibrationNeeded), (0x07, .calibrationNeeded), (0x08, .calibrationError), (0x09, .calibrationError),
            (0x0A, .calibrationError), (0x0B, .sensorFailed), (0x0C, .sensorFailed), (0x0D, .calibrationError),
            (0x0E, .calibrationNeeded), (0x0F, .expired), (0x10, .sensorFailed), (0x11, .sensorFailed),
            (0x12, .temporaryIssue), (0x13, .sensorFailed), (0x14, .sensorFailed), (0x15, .sensorFailed),
            (0x16, .sensorFailed), (0x17, .unknown), (0x18, .expired), (0x19, .sensorFailed), (0x1A, .expired),
            (0x1B, .sensorFailed), (0x24, .expired), (0x25, .sensorFailed), (0xFF, .unknown),
        ]
        for (raw, category) in expectations {
            XCTAssertEqual(G7AlgorithmState(rawValue: raw).category, category, "0x\(String(raw, radix: 16))")
        }
        XCTAssertEqual(G7AlgorithmState(rawValue: 0x42).name, "Unknown sensor state 0x42")
        XCTAssertEqual(G7AlgorithmState.warmUp.name, "Sensor warm-up")
    }
}

final class G7GlucoseRangeTests: XCTestCase {
    func test_S4_lowAndHighAreFlagsNeverClampedNumbers() {
        XCTAssertEqual(G7GlucoseRange.value(fromSensorMgdl: 39), .belowRange)
        XCTAssertEqual(G7GlucoseRange.value(fromSensorMgdl: 0), .belowRange)
        XCTAssertEqual(G7GlucoseRange.value(fromSensorMgdl: 40), .mgdl(40))
        XCTAssertEqual(G7GlucoseRange.value(fromSensorMgdl: 400), .mgdl(400))
        XCTAssertEqual(G7GlucoseRange.value(fromSensorMgdl: 401), .aboveRange)
        XCTAssertEqual(G7GlucoseRange.value(fromSensorMgdl: 0x0FFF), .aboveRange)
        for raw in UInt16(0)...0x0FFF {
            let value = G7GlucoseRange.value(fromSensorMgdl: raw)
            if case .mgdl(let mgdl) = value {
                XCTAssertTrue(GlucoseValue.sensorReportableRange.contains(mgdl))
                XCTAssertEqual(mgdl, Int(raw), "a number is never altered")
            }
        }
    }
}
