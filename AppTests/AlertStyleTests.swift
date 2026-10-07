import AlertEngine
import XCTest
@testable import Sensor

/// D53 vibrate-only alerts, screen side: the style mapping and edits, urgent low without a style
/// control (S7), the list subtitle, and "Set all to vibrate except urgent low".
final class AlertStyleTests: XCTestCase {
    func test_styleEditsRoundTrip() {
        var settings = AlertSettings.defaults
        settings = AlertsMapping.apply(.style(.low, .vibrateOnly), to: settings)
        XCTAssertEqual(AlertsMapping.row(.low, settings).style, .vibrateOnly)
        XCTAssertFalse(AlertsMapping.row(.low, settings).showsSoundSettings, "no sound picker or sound on silent")
        settings = AlertsMapping.apply(.style(.low, .sound), to: settings)
        XCTAssertEqual(AlertsMapping.row(.low, settings).style, .sound)
        XCTAssertTrue(AlertsMapping.row(.low, settings).showsSoundSettings)
        // Silent is for one-off events only.
        XCTAssertEqual(AlertsMapping.apply(.style(.low, .silent), to: settings), settings)
        settings = AlertsMapping.apply(.style(.sensorWarmUpComplete, .vibrateOnly), to: settings)
        XCTAssertEqual(AlertsMapping.row(.sensorWarmUpComplete, settings).style, .vibrateOnly)
    }

    /// S7: urgent low has no style control and no style edit changes it.
    func test_urgentLowHasNoStyleControl() {
        let row = AlertsMapping.row(.urgentLow, .defaults)
        XCTAssertEqual(row.allowedStyles, [.sound])
        XCTAssertFalse(row.hasStyleChoice)
        XCTAssertEqual(row.style, .sound)
        XCTAssertTrue(row.showsSoundSettings)
        for style in AlertStyle.allCases {
            XCTAssertEqual(AlertsMapping.apply(.style(.urgentLow, style), to: .defaults), .defaults, "\(style)")
        }
        XCTAssertEqual(AlertsText.urgentLowStyleNote, "Urgent low always sounds (it can't be set to vibrate).")
    }

    /// The convenience action: every sounding alert but urgent low vibrates; urgent low and silent
    /// announcements are unchanged; each alert can be set back on its own.
    func test_vibrateAllLeavesUrgentLowUnchanged() {
        var before = AlertSettings.defaults
        before = AlertsMapping.apply(.style(.sensorExpiringIn12Hours, .silent), to: before)
        let after = AlertsMapping.apply(.vibrateAllExceptUrgentLow, to: before)
        for kind in AlertKind.allCases {
            let row = AlertsMapping.row(kind, after)
            switch kind {
            case .urgentLow:
                XCTAssertEqual(row.style, .sound, "S7")
                XCTAssertEqual(row, AlertsMapping.row(.urgentLow, before), "urgent low untouched")
            case .sensorExpiringIn24Hours, .sensorExpiringIn12Hours:
                XCTAssertEqual(row.style, .silent, "\(kind): silent stays silent")
            default:
                XCTAssertEqual(row.style, .vibrateOnly, "\(kind)")
            }
        }
        // Thresholds, sounds and on/off are untouched.
        XCTAssertEqual(after.low.thresholdMgdl, before.low.thresholdMgdl)
        XCTAssertEqual(after.sound(.low), before.sound(.low))
        XCTAssertEqual(AlertKind.allCases.map { after.isEnabled($0) }, AlertKind.allCases.map { before.isEnabled($0) })
        // Reversible per alert.
        let oneBack = AlertsMapping.apply(.style(.high, .sound), to: after)
        XCTAssertEqual(AlertsMapping.row(.high, oneBack).style, .sound)
        XCTAssertEqual(AlertsMapping.row(.low, oneBack).style, .vibrateOnly)
    }

    /// The list subtitle's sound part.
    func test_listSubtitle() {
        var row = AlertsMapping.row(.low, .defaults)
        row.soundOnSilent = true
        XCTAssertEqual(AlertsText.soundSummary(row, soundName: "Low chime"), ["Low chime", "sounds on silent"])
        row.soundOnSilent = false
        XCTAssertEqual(AlertsText.soundSummary(row, soundName: "Low chime"), ["Low chime"])
        row.style = .vibrateOnly
        XCTAssertEqual(AlertsText.soundSummary(row, soundName: "Low chime"), ["vibrate only"])
        row.style = .silent
        XCTAssertEqual(AlertsText.soundSummary(row, soundName: "Low chime"), ["no sound"])
        XCTAssertEqual(AlertsText.styleNote(.vibrateOnly), "Vibrates without sound. Easy to miss while asleep.")
        XCTAssertNil(AlertsText.styleNote(.sound))
    }
}
