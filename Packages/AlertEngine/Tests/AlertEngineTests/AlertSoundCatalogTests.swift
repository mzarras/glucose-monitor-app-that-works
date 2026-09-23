import XCTest
@testable import AlertEngine

final class AlertSoundCatalogTests: XCTestCase {
    /// Repo root, from this file's location: Packages/AlertEngine/Tests/AlertEngineTests/<file>.
    private var soundsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Sounds")
    }

    func test_eightSoundsWithUniqueNamesAndFiles() {
        XCTAssertEqual(AlertSoundCatalog.all.count, 8, "HANDOFF §5: 6–8 sounds")
        XCTAssertEqual(Set(AlertSoundCatalog.all.map(\.fileName)).count, 8)
        XCTAssertEqual(Set(AlertSoundCatalog.all.map(\.displayName)).count, 8)
        for info in AlertSoundCatalog.all {
            XCTAssertTrue(info.fileName.hasPrefix("alert-"), "prefix keeps sound names apart from fonts in the bundle root")
            XCTAssertTrue(info.fileName.hasSuffix(".wav"))
            XCTAssertFalse(info.character.isEmpty)
        }
    }

    func test_everyAlertHasADefaultAndEveryFamilyItsOwnSound() {
        let byKind = Dictionary(uniqueKeysWithValues: AlertKind.allCases.map { ($0, AlertSoundCatalog.defaultSound(for: $0)) })
        // The families that must be distinguishable by ear each get a different sound.
        let families: [AlertKind] = [.urgentLow, .urgentLowSoon, .low, .high, .fallingFast, .missedReadings, .sensorWarmUpComplete, .sensorFailed]
        XCTAssertEqual(Set(families.map { byKind[$0]! }).count, families.count)
        XCTAssertEqual(Set(byKind.values), Set(AlertSoundID.allCases), "every sound is someone's default")
        for info in AlertSoundCatalog.all {
            XCTAssertEqual(info.defaultFor, AlertKind.allCases.filter { byKind[$0] == info.id })
        }
        XCTAssertEqual(AlertSettings.defaults.sound(.urgentLow), .cascade)
    }

    /// The committed files are what the catalog names, are linear PCM WAVE, and are under the
    /// 30-second limit for notification sounds.
    func test_bundledFilesExistAreWavAndUnder30Seconds() throws {
        for info in AlertSoundCatalog.all {
            let url = soundsDirectory.appendingPathComponent(info.fileName)
            let data = try Data(contentsOf: url)
            XCTAssertGreaterThan(data.count, 44, info.fileName)
            func text(_ range: Range<Int>) -> String { String(decoding: data[range], as: UTF8.self) }
            func u32(_ at: Int) -> UInt32 { data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
            func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
            XCTAssertEqual(text(0..<4), "RIFF")
            XCTAssertEqual(text(8..<12), "WAVE")
            XCTAssertEqual(text(12..<16), "fmt ")
            XCTAssertEqual(u16(20), 1, "linear PCM")
            XCTAssertEqual(u16(22), 1, "mono")
            let sampleRate = Double(u32(24))
            let bitsPerSample = Double(u16(34))
            XCTAssertEqual(text(36..<40), "data")
            let seconds = Double(u32(40)) / (sampleRate * bitsPerSample / 8)
            XCTAssertGreaterThan(seconds, 1, info.fileName)
            XCTAssertLessThan(seconds, 30, "\(info.fileName): notification sounds must be < 30 s")
        }
    }

    func test_noSoundFileNameCollidesWithAFont() throws {
        let fonts = soundsDirectory.deletingLastPathComponent().appendingPathComponent("Fonts")
        let fontNames = (try? FileManager.default.contentsOfDirectory(atPath: fonts.path)) ?? []
        XCTAssertTrue(Set(fontNames).isDisjoint(with: AlertSoundCatalog.all.map(\.fileName)))
    }
}
