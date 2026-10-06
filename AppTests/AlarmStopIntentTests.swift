// The urgent-low system alarm's Stop button at app level (D26, S7; Phase 2 review minor 6):
// `StopUrgentLowAlarmIntent.perform()` → `UrgentLowAlarmIntentBridge.shared` → the alert service
// the app routes it to (`AlarmIntentRouting`, as LiveAppServices connects it) → acknowledge, which
// snoozes urgent low for its snooze time, never more than 30 minutes.

import AlertEngine
import Foundation
import GlucoseCore
import XCTest
@testable import Sensor

@MainActor
final class AlarmStopIntentTests: XCTestCase {
    func test_S7_alarmStopIntentAcknowledgesUrgentLowForAtMost30Minutes() async throws {
        let clock = PipelineTestClock(PipelineFixtures.start)
        let center = RecordingNotificationCenter(clock: clock)
        let ports = AlertPorts(
            notificationCenter: center, audio: RecordingAudioPlayer(clock: clock), alarms: nil,
            configuration: PipelineFixtures.utcConfiguration, diagnostics: NullDiagnosticLog()
        )
        let service = ports.makeProductionService(settings: .defaults, snapshot: nil, clock: PipelineAlertClock(now: clock.closure, uptime: nil)) { _ in }
        await service.start()
        await service.send(.reading(PipelineFixtures.reading(.mgdl(49), at: PipelineFixtures.start.addingTimeInterval(-30)), session: PipelineFixtures.session))
        guard case .firing = service.phase(of: .urgentLow) else {
            return XCTFail("urgent low should be firing: \(service.phase(of: .urgentLow))")
        }

        await AlarmIntentRouting.connect(UrgentLowAlarmIntentBridge.shared) { service }
        if #available(iOS 26.0, *) {
            _ = try await StopUrgentLowAlarmIntent().perform()
        } else {
            return XCTFail("AlarmKit's Stop intent needs iOS 26; run this test on an iOS 26 simulator")
        }

        guard case .snoozed(let until) = service.phase(of: .urgentLow) else {
            return XCTFail("Stop must acknowledge urgent low: \(service.phase(of: .urgentLow))")
        }
        let maximum = clock.now.addingTimeInterval(TimeInterval(AlertLimits.urgentLowMaximumSnoozeMinutes * 60))
        XCTAssertLessThanOrEqual(until, maximum, "S7: never more than 30 minutes")
        XCTAssertEqual(until, clock.now.addingTimeInterval(TimeInterval(service.settings.urgentLow.snoozeMinutes * 60)))
        XCTAssertTrue(center.pending("urgentLow").isEmpty, "acknowledge removes the pending repeats")
    }
}
