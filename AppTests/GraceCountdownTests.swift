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
        // Review m7: one live countdown (the body). The banner says when readings stop, with no
        // duration; the time left is not repeated there.
        let banner = state.banners(now: before, context: testContext).first { $0.kind == .sensorExpiring }
        XCTAssertEqual(banner?.title, "Sensor in grace period")
        XCTAssertEqual(banner?.detail, "Readings stop at \(TimeText.time(end, testContext)). Replace the sensor soon.")
        XCTAssertFalse(banner?.detail.contains("left") ?? true)

        XCTAssertNil(GraceCountdown.end(sensorState: grace, now: end), "at zero the countdown goes")
        guard case .sensorExpired = state.display(now: end) else { return XCTFail("expired takes over at the end") }
        guard case .message(let title, _, _) = NowHero.make(state.display(now: end), now: end) else { return XCTFail("hero message") }
        XCTAssertEqual(title, "Sensor expired")
        XCTAssertTrue(state.banners(now: end, context: testContext).contains { $0.kind == .sensorExpired })
        XCTAssertFalse(state.banners(now: end, context: testContext).contains { $0.kind == .sensorExpiring })
    }

    /// Review m9: a tick scheduled at the grace end that fires a few milliseconds early still
    /// renders the end (the later of the scheduled date and the clock), so "Sensor expired" shows at
    /// zero rather than on the next 15 s tick.
    func test_anEarlyTickAtTheGraceEndStillSwitchesToExpired() {
        var state = NowViewState.empty
        state.sensorState = .gracePeriod(endsAt: end)
        state.latestLiveReading = latest(.mgdl(120), ageMinutes: 2, now: end.addingTimeInterval(-60))
        let earlyClock = end.addingTimeInterval(-0.004)
        guard case .current = state.display(now: earlyClock) else { return XCTFail("4 ms before the end it is still grace") }
        let rendered = NowRefreshSchedule.renderDate(scheduled: end, clock: earlyClock)
        XCTAssertEqual(rendered, end)
        guard case .sensorExpired = state.display(now: rendered) else { return XCTFail("the tick at the end renders expired") }
        XCTAssertNil(GraceCountdown.end(sensorState: state.sensorState, now: rendered))
        // A late tick keeps the clock (later than the schedule).
        XCTAssertEqual(NowRefreshSchedule.renderDate(scheduled: end, clock: end.addingTimeInterval(2)), end.addingTimeInterval(2))
    }

    /// Review n1: after the phone's clock is set back 10 min, TimelineView can still hand over an
    /// entry dated before the change; the screen renders at the clock, not 10 min in the future, so a
    /// current reading stays current.
    func test_clockSetBackRendersAtTheClockNotAStaleEntry() {
        let staleEntry = t0
        let clockSetBack = t0.addingTimeInterval(-10 * 60)
        XCTAssertEqual(NowRefreshSchedule.renderDate(scheduled: staleEntry, clock: clockSetBack), clockSetBack)
        var state = NowViewState.empty
        state.sensorState = activeSensor
        state.latestLiveReading = latest(.mgdl(120), ageMinutes: 2, now: clockSetBack)
        guard case .current = state.display(now: NowRefreshSchedule.renderDate(scheduled: staleEntry, clock: clockSetBack)) else {
            return XCTFail("a reading 2 min old by the phone clock is current")
        }
        // The early-tick window is under a second: 0.999 s ahead still renders the schedule.
        XCTAssertEqual(NowRefreshSchedule.renderDate(scheduled: t0, clock: t0.addingTimeInterval(-0.999)), t0)
        XCTAssertEqual(NowRefreshSchedule.renderDate(scheduled: t0, clock: t0.addingTimeInterval(-1)), t0.addingTimeInterval(-1))
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
