// Pending repeats (urgent low; missed readings) — safety review WS4 B2.
//
// The app may be suspended when a repeat is due, so each one is a pending notification (and, for
// urgent low on iOS 26+, a system alarm) scheduled ahead. A BLE wake-up close to a repeat must not
// disturb it: the review found that rescheduling "everything from the next slot" cancelled the
// repeat due 30 s later (so it never rang) or stopped the one ringing 3 s in. So:
//
//   • Every pending repeat the engine asks for is recorded as (sequence number, fire date). Its
//     notification identifier and alarm ID come from the sequence number (`slot`), never from its
//     position in a list, so a later reschedule cannot reuse the ID of one still pending.
//   • Planning is a diff against the grid the alert repeats on. Entries due within
//     `protectedLeadTime` (60 s) or already past are NEVER cancelled or replaced. Later entries that
//     are not on the grid are cancelled by slot; missing grid points are added with new sequence
//     numbers. On the same grid, rolling forward only adds the tail.
//   • The sequence and dates are in the snapshot, so all of this is re-derived after a relaunch.

import Foundation

/// One pending repeat the engine has scheduled.
public struct ScheduledRepeat: Sendable, Equatable, Codable {
    public let sequence: Int
    public let date: Date

    /// Names the notification (`AlertNotificationIDs.scheduled`) and alarm (`SystemAlarmIDs.repeatSlot`).
    public var slot: Int { sequence % AlertLimits.scheduleIDCycle }
}

/// The pending repeats of one alert, in date order.
public struct RepeatSeries: Sendable, Equatable, Codable {
    public var entries: [ScheduledRepeat] = []
    public var nextSequence = 0
}

extension AlertEngine {
    func series(_ kind: AlertKind) -> RepeatSeries {
        snapshot.repeatSeries[kind.rawValue] ?? RepeatSeries()
    }

    private mutating func setSeries(_ kind: AlertKind, _ series: RepeatSeries) {
        snapshot.repeatSeries[kind.rawValue] = series
    }

    /// Entries at or before this are due or ringing: never touched by a reschedule.
    static func protectedUntil(_ now: Date) -> Date {
        now.addingTimeInterval(AlertLimits.protectedLeadTime)
    }

    /// Makes the series for `kind` hold the first `count` grid points `anchor + k × interval`
    /// (k ≥ `firstIndex`) that are later than the protected window, touching only what differs.
    mutating func planSeries(
        _ kind: AlertKind, anchor: Date, interval: TimeInterval, firstIndex: Int, count: Int, now: Date, isRepeat: Bool
    ) -> [AlertAction] {
        let protectedUntil = Self.protectedUntil(now)
        var series = series(kind)
        series.entries.removeAll { $0.date < now.addingTimeInterval(-AlertLimits.seriesMemory) }

        let desired = Self.gridDates(anchor: anchor, interval: interval, firstIndex: firstIndex, after: protectedUntil, count: count)
        let desiredSet = Set(desired)
        let protected = series.entries.filter { $0.date <= protectedUntil }
        let future = series.entries.filter { $0.date > protectedUntil }
        let obsolete = future.filter { !desiredSet.contains($0.date) }
        let kept = future.filter { desiredSet.contains($0.date) }
        let keptDates = Set(kept.map(\.date))

        var added: [ScheduledRepeat] = []
        for date in desired where !keptDates.contains(date) {
            added.append(ScheduledRepeat(sequence: series.nextSequence, date: date))
            series.nextSequence += 1
        }
        series.entries = (protected + kept + added).sorted { $0.date < $1.date }
        setSeries(kind, series)

        var actions: [AlertAction] = []
        if !obsolete.isEmpty {
            actions.append(.cancelSlots(kind, obsolete.map(\.slot)))
        }
        if !added.isEmpty {
            actions.append(.schedule(kind, added.map { makeNotice(kind, fireDate: $0.date, now: now, isRepeat: isRepeat, slot: $0.slot) }))
        }
        return actions
    }

    /// Cancels the entries due later than the protected window (they are rebuilt by the next plan,
    /// e.g. with new settings); due and ringing ones stay.
    mutating func cancelFutureSeries(_ kind: AlertKind, now: Date) -> [AlertAction] {
        var series = series(kind)
        let protectedUntil = Self.protectedUntil(now)
        let future = series.entries.filter { $0.date > protectedUntil }
        series.entries.removeAll { $0.date > protectedUntil }
        setSeries(kind, series)
        return future.isEmpty ? [] : [.cancelSlots(kind, future.map(\.slot))]
    }

    /// After a relaunch the list and the system may disagree (the process can die between the two).
    /// Cancels every slot except the protected ones, so the next plan starts from a known state.
    mutating func resetSeriesAfterLaunch(_ kind: AlertKind, now: Date) -> [AlertAction] {
        var series = series(kind)
        let protectedUntil = Self.protectedUntil(now)
        series.entries.removeAll { $0.date > protectedUntil }
        setSeries(kind, series)
        let protectedSlots = Set(series.entries.map(\.slot))
        let slots = (0..<AlertLimits.scheduleIDCycle).filter { !protectedSlots.contains($0) }
        return [.cancelSlots(kind, slots)]
    }

    /// The alert's notifications and alarms were all removed (`.cancel` / `.cancelScheduled`).
    mutating func forgetSeries(_ kind: AlertKind) {
        var series = series(kind)
        series.entries = []
        setSeries(kind, series)
    }

    /// The pending entry for a due repeat at `date`, if one was scheduled.
    func scheduledEntry(_ kind: AlertKind, at date: Date) -> ScheduledRepeat? {
        series(kind).entries.first { $0.date == date }
    }

    /// `anchor + k × interval` for k = firstIndex, firstIndex + 1, …, keeping only times after
    /// `after`, until `count` are collected (capped at `maximumScheduledSlots`).
    static func gridDates(anchor: Date, interval: TimeInterval, firstIndex: Int, after: Date, count: Int) -> [Date] {
        guard interval > 0 else { return [] }
        var dates: [Date] = []
        var k = firstIndex
        if anchor < after {
            k = max(k, Int((after.timeIntervalSince(anchor) / interval).rounded(.down)))
        }
        while dates.count < min(count, AlertLimits.maximumScheduledSlots) {
            let date = anchor.addingTimeInterval(Double(k) * interval)
            if date > after { dates.append(date) }
            k += 1
        }
        return dates
    }
}
