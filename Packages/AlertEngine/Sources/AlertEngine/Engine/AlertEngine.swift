// The alert engine (HANDOFF §5, brief items 2–4): a value type that takes one input and the
// current time and returns the actions to perform. No I/O, no clocks, no concurrency, so every
// behaviour is tested by feeding inputs at chosen times and comparing the returned actions.
//
// Split across files by concern:
//   AlertEngine.swift                  inputs, the per-alert state machine, glucose alerts
//   AlertEngine+MissedReadings.swift   the pre-scheduled missed-readings alert (S5)
//   AlertEngine+Sensor.swift           sensor state, sensor announcements
//   AlertEngine+User.swift             acknowledge / snooze / settings changes

import Foundation
import GlucoseCore

public struct AlertEngine: Sendable {
    public internal(set) var settings: AlertSettings
    public let configuration: AlertEngineConfiguration
    /// Persist this after every `handle` call and pass it back on the next launch.
    public internal(set) var snapshot: AlertEngineSnapshot

    public init(
        settings: AlertSettings,
        configuration: AlertEngineConfiguration = AlertEngineConfiguration(),
        restoring snapshot: AlertEngineSnapshot? = nil,
        now: Date
    ) {
        self.settings = settings
        self.configuration = configuration
        self.snapshot = snapshot.map { Self.sanitized($0, now: now) } ?? AlertEngineSnapshot(start: now)
    }

    /// Makes a restored snapshot safe to use.
    static func sanitized(_ stored: AlertEngineSnapshot, now: Date) -> AlertEngineSnapshot {
        var s = stored
        s.episodes = s.episodes.filter { AlertKind(rawValue: $0.key) != nil }
        // S7: whatever the stored file says, an urgent-low snooze ends at most 30 minutes after it
        // was made, and at most 30 minutes from now (in case the clock moved backwards).
        if case .snoozed(let snooze) = s.episodes[AlertKind.urgentLow.rawValue] {
            let maximum = TimeInterval(AlertLimits.urgentLowMaximumSnoozeMinutes * 60)
            let until = min(snooze.until, snooze.snoozedAt.addingTimeInterval(maximum), now.addingTimeInterval(maximum))
            s.episodes[AlertKind.urgentLow.rawValue] = .snoozed(AlertSnooze(snoozedAt: min(snooze.snoozedAt, now), until: until))
        }
        return s
    }

    // MARK: Reading the state (for the UI)

    public func phase(of kind: AlertKind) -> AlertPhase {
        guard settings.isEnabled(kind) else { return .off }
        switch episode(kind) {
        case .armed: return .armed
        case .delaying(let since): return .pending(firesAt: since.addingTimeInterval(delay(for: kind)))
        case .firing(let firing): return .firing(since: firing.since)
        case .snoozed(let snooze): return .snoozed(until: snooze.until)
        }
    }

    /// Alerts with an episode in progress (firing or snoozed), most important first.
    public var activeAlerts: [AlertKind] {
        AlertKind.allCases.filter { episode($0).isActive }
    }

    /// The latest live reading if it is still current, else `nil` (S1: never carried forward).
    public func currentReading(at now: Date) -> LiveReadingSummary? {
        guard let reading = snapshot.latestLiveReading else { return nil }
        return now.timeIntervalSince(reading.date) <= AlertLimits.currentReadingMaximumAge ? reading : nil
    }

    // MARK: The one entry point

    public mutating func handle(_ input: AlertInput, at now: Date) -> [AlertAction] {
        var actions: [AlertAction] = []
        switch input {
        case .reading(let reading, let session):
            if let rejection = Self.rejection(of: reading, session: session, now: now, configuration: configuration) {
                // Refused (S2/S6): change nothing at all, not even the missed-readings clock.
                return [.readingRejected(readingID: reading.id, reason: rejection)]
            }
            accept(reading)
        case .sensorState(let state):
            actions += receive(state, now: now)
        case .trioBridge(let status):
            snapshot.bridgeStatus = status
        case .tick:
            break
        case .user(let action):
            actions += apply(action, now: now)
        case .settings(let newSettings):
            actions += apply(newSettings, now: now)
        }
        actions += evaluate(now: now)
        return actions
    }

    // MARK: Readings

    /// S2/S6: every reading passes `LiveReadingGate` here. Release builds call only `validate`
    /// (live `.sensor` readings); `validateAllowingReplay` exists only in DEBUG builds (D11).
    static func rejection(
        of reading: GlucoseReading, session: SensorSession?, now: Date, configuration: AlertEngineConfiguration
    ) -> LiveReadingGate.Rejection? {
        do {
            #if DEBUG
            if configuration.acceptsReplayReadings {
                try LiveReadingGate.validateAllowingReplay(reading, session: session, now: now)
            } else {
                try LiveReadingGate.validate(reading, session: session, now: now)
            }
            #else
            try LiveReadingGate.validate(reading, session: session, now: now)
            #endif
            return nil
        } catch {
            return error
        }
    }

    private mutating func accept(_ reading: GlucoseReading) {
        if reading.date > (snapshot.lastValidReadingDate ?? .distantPast) {
            snapshot.lastValidReadingDate = reading.date
        }
        // Any valid reading, backfill included, proves data is flowing up to its date.
        if reading.date > snapshot.missedReadingsReference {
            snapshot.missedReadingsReference = reading.date
        }
        // Glucose alerts evaluate only the newest live reading. A backfilled reading never does,
        // and neither does a live reading older than one already seen (Loop found a G7 backfill
        // retracting a fresh urgent low: LoopKit/Loop #2520, GlucoseAlertManager.swift:588-594).
        if !reading.isBackfill, reading.date > (snapshot.latestLiveReading?.date ?? .distantPast) {
            snapshot.latestLiveReading = LiveReadingSummary(reading)
        }
    }

    // MARK: Evaluation

    private mutating func evaluate(now: Date) -> [AlertAction] {
        var actions: [AlertAction] = []
        let current = currentReading(at: now)

        actions += step(.urgentLow, GlucoseConditions.atOrBelow(current, threshold: settings.urgentLow.thresholdMgdl), now: now)
        let urgentLowActive = episode(.urgentLow).isActive
        actions += step(.urgentLowSoon, GlucoseConditions.urgentLowSoon(
            current, urgentLowThreshold: settings.urgentLow.thresholdMgdl, urgentLowActive: urgentLowActive), now: now)
        actions += step(.low, GlucoseConditions.low(current, threshold: settings.low.thresholdMgdl, urgentLowActive: urgentLowActive), now: now)
        actions += step(.high, GlucoseConditions.atOrAbove(current, threshold: settings.high.thresholdMgdl), now: now)
        actions += step(.fallingFast, GlucoseConditions.fallingFast(current, threshold: settings.fallingFast.thresholdMgdlPerMinute), now: now)
        actions += step(.risingFast, GlucoseConditions.risingFast(current, threshold: settings.risingFast.thresholdMgdlPerMinute), now: now)

        actions += stepMissedReadings(now: now)

        actions += step(.sensorFailed, StatusConditions.sensorFailed(snapshot.settledSensorState), now: now)
        actions += step(.sensorError, StatusConditions.sensorError(snapshot.settledSensorState), now: now)
        actions += step(.sensorExpired, StatusConditions.sensorExpired(snapshot.settledSensorState), now: now)
        actions += step(.bluetoothUnavailable, StatusConditions.bluetoothUnavailable(snapshot.lastReportedSensorState), now: now)
        actions += step(.trioBridge, StatusConditions.trioBridge(snapshot.bridgeStatus, now: now), now: now)

        actions += announceExpiryAndGracePeriod(now: now)
        return actions
    }

    /// The state machine for every condition alert except missed readings.
    private mutating func step(_ kind: AlertKind, _ condition: AlertCondition, now: Date) -> [AlertAction] {
        guard settings.isEnabled(kind) else {
            // Turned off: clear whatever was in progress. Never happens to urgent low (S7).
            guard episode(kind) != .armed else { return [] }
            setEpisode(kind, .armed)
            return [.cancel(kind)]
        }
        switch (episode(kind), condition) {
        case (.armed, .met):
            if delay(for: kind) > 0 {
                setEpisode(kind, .delaying(since: now))
                return []
            }
            return fire(kind, now: now)
        case (.armed, _):
            return []

        case (.delaying(let since), .met):
            return now.timeIntervalSince(since) >= delay(for: kind) ? fire(kind, now: now) : []
        case (.delaying, .holding):
            return []
        case (.delaying, .clear):
            setEpisode(kind, .armed)
            return []

        case (.firing, .clear), (.snoozed, .clear):
            setEpisode(kind, .armed)
            return [.cancel(kind)]
        case (.firing(let firing), _):
            return repeatIfDue(kind, firing, condition: condition, now: now)

        case (.snoozed(let snooze), .met):
            return now >= snooze.until ? fire(kind, now: now) : []
        case (.snoozed, .holding):
            return []
        }
    }

    private mutating func fire(_ kind: AlertKind, now: Date) -> [AlertAction] {
        setEpisode(kind, .firing(AlertFiring(since: now, lastSoundedAt: now)))
        var actions: [AlertAction] = [.fire(makeNotice(kind, fireDate: nil, now: now))]
        if kind == .urgentLow {
            actions.append(scheduleUrgentLowRepeats(after: now, now: now))
        }
        return actions
    }

    private mutating func repeatIfDue(_ kind: AlertKind, _ firing: AlertFiring, condition: AlertCondition, now: Date) -> [AlertAction] {
        if kind == .urgentLow {
            // Repeats every `repeatMinutes` until acknowledged (HANDOFF §4.7), whether or not the
            // latest value is still current: the alert was raised on a real reading and nobody has
            // acknowledged it. The pending notifications keep repeating it while the app sleeps;
            // this adds the ringer-off sound whenever the app is awake. It ends only on
            // acknowledge/snooze or a reading that clears it.
            let interval = urgentLowRepeatInterval
            let slot = Self.latestSlot(anchor: firing.since, interval: interval, now: now)
            guard slot > firing.lastSoundedAt else { return [] }
            setEpisode(kind, .firing(AlertFiring(since: firing.since, lastSoundedAt: slot)))
            return [
                .playDueAlert(makeNotice(kind, fireDate: nil, now: now, isRepeat: true)),
                scheduleUrgentLowRepeats(after: slot, now: now),
            ]
        }
        // Every other alert re-alerts at its snooze interval, but only on a current reading or
        // state that still meets the condition.
        guard condition == .met, let minutes = settings.snoozeMinutes(kind) else { return [] }
        guard now.timeIntervalSince(firing.lastSoundedAt) >= TimeInterval(minutes * 60) else { return [] }
        setEpisode(kind, .firing(AlertFiring(since: firing.since, lastSoundedAt: now)))
        return [.fire(makeNotice(kind, fireDate: nil, now: now))]
    }

    /// Pending notifications for the next `scheduledNotificationCount` repeats after `anchor`.
    func scheduleUrgentLowRepeats(after anchor: Date, now: Date) -> AlertAction {
        let dates = Self.futureSlots(anchor: anchor, interval: urgentLowRepeatInterval, firstIndex: 1, after: now)
        return .schedule(.urgentLow, dates.map { makeNotice(.urgentLow, fireDate: $0, now: now, isRepeat: true) })
    }

    var urgentLowRepeatInterval: TimeInterval {
        TimeInterval(settings.urgentLow.repeatMinutes * 60)
    }

    /// The latest `anchor + k × interval` (k ≥ 0) that is not after `now`.
    static func latestSlot(anchor: Date, interval: TimeInterval, now: Date) -> Date {
        guard interval > 0, now > anchor else { return anchor }
        let k = (now.timeIntervalSince(anchor) / interval).rounded(.down)
        return anchor.addingTimeInterval(k * interval)
    }

    /// `anchor + k × interval` for k = firstIndex, firstIndex + 1, …, keeping only times after
    /// `now`, until `scheduledNotificationCount` are collected. Never schedules the past.
    static func futureSlots(anchor: Date, interval: TimeInterval, firstIndex: Int, after now: Date) -> [Date] {
        guard interval > 0 else { return [] }
        var dates: [Date] = []
        var k = firstIndex
        if anchor < now {
            // Skip straight to the first slot after `now`.
            k = max(k, Int((now.timeIntervalSince(anchor) / interval).rounded(.down)))
        }
        while dates.count < AlertLimits.scheduledNotificationCount {
            let date = anchor.addingTimeInterval(Double(k) * interval)
            if date > now { dates.append(date) }
            k += 1
        }
        return dates
    }

    // MARK: Helpers shared by the extensions

    func episode(_ kind: AlertKind) -> AlertEpisode {
        snapshot.episodes[kind.rawValue] ?? .armed
    }

    mutating func setEpisode(_ kind: AlertKind, _ episode: AlertEpisode) {
        snapshot.episodes[kind.rawValue] = episode
    }

    func delay(for kind: AlertKind) -> TimeInterval {
        kind == .high ? TimeInterval(settings.high.delayMinutes * 60) : 0
    }

    func makeNotice(_ kind: AlertKind, fireDate: Date?, now: Date, isRepeat: Bool = false) -> AlertNotice {
        let deliveredAt = fireDate ?? now
        // S7: quiet hours never silence urgent low.
        let silenced = kind != .urgentLow && settings.quietHours.contains(deliveredAt, calendar: configuration.calendar)
        let context = AlertTextContext(
            reading: snapshot.latestLiveReading,
            lastValidReadingDate: snapshot.lastValidReadingDate,
            settings: settings,
            settledSensorState: snapshot.settledSensorState,
            lastReportedSensorState: snapshot.lastReportedSensorState,
            bridgeStatus: snapshot.bridgeStatus,
            calendar: configuration.calendar,
            locale: configuration.locale
        )
        return AlertNotice(
            kind: kind,
            title: AlertText.title(kind),
            body: AlertText.body(kind, context: context, isRepeat: isRepeat),
            sound: settings.sound(kind),
            soundsOnSilent: settings.soundsOnSilent(kind),
            isSilenced: silenced,
            snoozeMinutes: settings.snoozeMinutes(kind),
            fireDate: fireDate
        )
    }
}
