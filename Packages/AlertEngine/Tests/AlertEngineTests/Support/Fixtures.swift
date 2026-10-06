import Foundation
import GlucoseCore
@testable import AlertEngine

enum Fixtures {
    /// 2026-09-23 12:00:00 UTC (hand-computed: 1_790_164_800 s since 1970).
    static let t0 = Date(timeIntervalSince1970: 1_790_164_800)
    static let serial = "3MTEST"

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    static var configuration: AlertEngineConfiguration {
        AlertEngineConfiguration(calendar: utc, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A session two days old at t0: warm-up long over, 8 days left.
    static let session = SensorSession(
        serial: serial,
        start: t0.addingTimeInterval(-2 * 86_400),
        warmUpEndsAt: t0.addingTimeInterval(-2 * 86_400 + 30 * 60),
        expiresAt: t0.addingTimeInterval(8 * 86_400),
        gracePeriodEndsAt: t0.addingTimeInterval(8 * 86_400 + 12 * 3_600)
    )

    static func reading(
        _ value: GlucoseValue,
        at date: Date,
        rate: Double? = 0,
        backfill: Bool = false,
        source: ReadingSource = .sensor,
        serial: String = serial
    ) -> GlucoseReading {
        let sensorTimestamp = UInt32(max(0, date.timeIntervalSince(session.start)))
        return GlucoseReading(
            id: GlucoseReading.sensorID(serial: serial, sensorTimestamp: sensorTimestamp),
            date: date, value: value, trendRate: rate, isBackfill: backfill, source: source, sensorSerial: serial
        )
    }
}

/// An engine plus a test clock, with shorthand for feeding it.
@MainActor
final class EngineHarness {
    let clock = TestClock()
    var engine: AlertEngine
    var session: SensorSession? = Fixtures.session

    init(settings: AlertSettings = .defaults, configuration: AlertEngineConfiguration = Fixtures.configuration) {
        engine = AlertEngine(settings: settings, configuration: configuration, now: clock.now)
    }

    var now: Date { clock.now }

    @discardableResult
    func send(_ input: AlertInput) -> [AlertAction] {
        engine.handle(input, at: clock.now, uptime: clock.uptime)
    }

    /// A live sensor reading measured `secondsAgo` before now.
    @discardableResult
    func reading(_ value: GlucoseValue, rate: Double? = 0, secondsAgo: TimeInterval = 0, backfill: Bool = false, source: ReadingSource = .sensor) -> [AlertAction] {
        let r = Fixtures.reading(value, at: clock.now.addingTimeInterval(-secondsAgo), rate: rate, backfill: backfill, source: source)
        return send(.reading(r, session: session))
    }

    @discardableResult
    func mgdl(_ value: Int, rate: Double? = 0) -> [AlertAction] {
        reading(.mgdl(value), rate: rate)
    }

    @discardableResult
    func tick() -> [AlertAction] {
        send(.tick)
    }

    @discardableResult
    func advance(minutes: Double) -> [AlertAction] {
        clock.advance(minutes: minutes)
        return tick()
    }

    @discardableResult
    func user(_ action: AlertUserAction) -> [AlertAction] {
        send(.user(action))
    }

    @discardableResult
    func settings(_ change: (inout AlertSettings) -> Void) -> [AlertAction] {
        var s = engine.settings
        change(&s)
        return send(.settings(s))
    }

    func phase(_ kind: AlertKind) -> AlertPhase {
        engine.phase(of: kind)
    }

    /// Fire dates of the repeats the engine keeps pending for `kind` that are still in the future.
    func pendingDates(_ kind: AlertKind) -> [Date] {
        engine.series(kind).entries.map(\.date).filter { $0 > now }
    }
}

extension Array where Element == AlertAction {
    var fired: [AlertKind] {
        compactMap { if case .fire(let n) = $0 { return n.kind } else { return nil } }
    }

    var due: [AlertKind] {
        compactMap { if case .playDueAlert(let n) = $0 { return n.kind } else { return nil } }
    }

    var cancelled: [AlertKind] {
        compactMap { if case .cancel(let k) = $0 { return k } else { return nil } }
    }

    var rejected: [LiveReadingGate.Rejection] {
        compactMap { if case .readingRejected(_, let reason) = $0 { return reason } else { return nil } }
    }

    func firedNotice(_ kind: AlertKind) -> AlertNotice? {
        for case .fire(let n) in self where n.kind == kind { return n }
        return nil
    }

    func dueNotice(_ kind: AlertKind) -> AlertNotice? {
        for case .playDueAlert(let n) in self where n.kind == kind { return n }
        return nil
    }

    /// Fire dates of the last `.schedule` for `kind`, or nil if none.
    func scheduled(_ kind: AlertKind) -> [Date]? {
        var result: [Date]?
        for case .schedule(let k, let notices) in self where k == kind {
            result = notices.compactMap(\.fireDate)
        }
        return result
    }

    func scheduledNotices(_ kind: AlertKind) -> [AlertNotice]? {
        var result: [AlertNotice]?
        for case .schedule(let k, let notices) in self where k == kind { result = notices }
        return result
    }

    /// Everything except bookkeeping for missed readings, which reschedules on every reading.
    var ignoringMissedReadings: [AlertAction] {
        filter {
            switch $0 {
            case .schedule(.missedReadings, _), .cancel(.missedReadings), .cancelScheduled(.missedReadings), .cancelSlots(.missedReadings, _):
                return false
            default: return true
            }
        }
    }
}

func minutes(_ m: Double) -> TimeInterval { m * 60 }
