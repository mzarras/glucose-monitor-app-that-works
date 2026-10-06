import GlucoseCore
import SwiftUI
import WidgetCore
import XCTest
@testable import Sensor

/// PROGRESS D43: the live grace-period countdown on the Now screen.
final class GraceCountdownTests: XCTestCase {
    private let end = minutes(7 * 60 + 40, from: t0).addingTimeInterval(12) // 7:40:12 after t0

    func test_countdownFormatting() {
        XCTAssertEqual(GraceCountdown.clock(until: end, now: t0), "7:40:12")
        XCTAssertEqual(GraceCountdown.clock(until: t0.addingTimeInterval(12 * 3_600), now: t0), "12:00:00")
        XCTAssertEqual(GraceCountdown.clock(until: t0.addingTimeInterval(309), now: t0), "0:05:09")
        XCTAssertEqual(GraceCountdown.clock(until: t0.addingTimeInterval(0.4), now: t0), "0:00:01", "rounded up: 0:00:00 only at the end")
        XCTAssertEqual(GraceCountdown.clock(until: t0, now: t0.addingTimeInterval(5)), "0:00:00", "never negative")
    }

    func test_voiceOverLabelToTheMinute() {
        XCTAssertEqual(GraceCountdown.spoken(until: end, now: t0), "Grace period, 7 hours 40 minutes left")
        XCTAssertEqual(GraceCountdown.spoken(until: t0.addingTimeInterval(3_600), now: t0), "Grace period, 1 hour left")
        XCTAssertEqual(GraceCountdown.spoken(until: t0.addingTimeInterval(61 * 60), now: t0), "Grace period, 1 hour 1 minute left")
        XCTAssertEqual(GraceCountdown.spoken(until: t0.addingTimeInterval(59), now: t0), "Grace period, less than a minute left")
    }

    /// Shown only during the grace period and while its end is ahead; at the end the existing
    /// expired state takes over (hero, state line, banner).
    func test_stateSwitchAtTheEnd() {
        let grace = SensorState.gracePeriod(endsAt: end)
        XCTAssertEqual(GraceCountdown.end(sensorState: grace, now: t0), end)
        XCTAssertNil(GraceCountdown.end(sensorState: activeSensor, now: t0), "not before grace")
        XCTAssertNil(GraceCountdown.end(sensorState: .expired, now: t0))

        var state = NowViewState.empty
        state.sensorState = grace
        state.latestLiveReading = latest(.mgdl(120), ageMinutes: 2, now: end.addingTimeInterval(-60))
        let before = end.addingTimeInterval(-1)
        XCTAssertNotNil(GraceCountdown.end(sensorState: grace, now: before))
        XCTAssertTrue(state.banners(now: before, context: testContext).contains { $0.kind == .sensorExpiring && $0.countdownEnd == end },
                      "the grace banner carries the countdown")

        XCTAssertNil(GraceCountdown.end(sensorState: grace, now: end), "at zero the countdown goes")
        guard case .sensorExpired = state.display(now: end) else { return XCTFail("expired takes over at the end") }
        guard case .message(let title, _, _) = NowHero.make(state.display(now: end), now: end) else { return XCTFail("hero message") }
        XCTAssertEqual(title, "Sensor expired")
        XCTAssertTrue(state.banners(now: end, context: testContext).contains { $0.kind == .sensorExpired })
        XCTAssertFalse(state.banners(now: end, context: testContext).contains { $0.countdownEnd != nil })
    }

    /// The Now screen's clock ticks every 15 s and exactly at the grace end, so the switch happens
    /// at zero, not up to 15 s later.
    @MainActor
    func test_refreshScheduleTicksAtTheGraceEnd() {
        let schedule = NowRefreshSchedule(interval: 15, extraDates: [t0.addingTimeInterval(20)])
        var ticks: [TimeInterval] = []
        for date in schedule.entries(from: t0, mode: .normal).prefix(5) { ticks.append(date.timeIntervalSince(t0)) }
        XCTAssertEqual(ticks, [0, 15, 20, 30, 45])
        let plain = NowRefreshSchedule(interval: 15, extraDates: [])
        XCTAssertEqual(Array(plain.entries(from: t0, mode: .normal).prefix(3)).map { $0.timeIntervalSince(t0) }, [0, 15, 30])
    }

    /// The countdown renders on the Now screen (light and dark) with its VoiceOver label.
    @MainActor
    func test_countdownRendersOnTheNowScreen() throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = NowContent(state: Fixtures.now(.gracePeriod, at: t0), calibration: Fixtures.calibration(.available, at: t0), now: t0,
                                  actions: .noop, context: testContext)
                .frame(width: 390)
                .editorialScreen()
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
            XCTAssertNotNil(renderer.uiImage, "\(scheme)")
        }
        XCTAssertEqual(GraceCountdown.clock(until: GraceCountdown.end(sensorState: Fixtures.now(.gracePeriod, at: t0).sensorState, now: t0)!, now: t0),
                       "7:40:12")
    }
}
