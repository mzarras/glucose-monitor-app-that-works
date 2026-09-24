// Every configurable range and default in one place (HANDOFF §5). Settings clamp to these on
// every path: initialisers, property setters, and decoding stored settings.

import Foundation

public enum AlertLimits {
    // MARK: Urgent low (S7)

    /// HANDOFF §5: threshold configurable 50–60 mg/dL, default 55.
    public static let urgentLowThresholdMgdl: ClosedRange<Int> = 50...60
    public static let urgentLowDefaultThresholdMgdl = 55
    /// S7: urgent low can be snoozed for at most 30 minutes. This is the only place the 30 lives.
    public static let urgentLowMaximumSnoozeMinutes = 30
    public static let urgentLowSnoozeMinutes: ClosedRange<Int> = 1...urgentLowMaximumSnoozeMinutes
    /// After acknowledging, urgent low re-alerts after this long if glucose is still urgent-low.
    public static let urgentLowDefaultSnoozeMinutes = 30
    /// HANDOFF §4.7: repeat unacknowledged urgent alerts every 5 minutes. The interval may be set
    /// shorter, never longer, and repeating can never be turned off. The floor is 2 minutes so that
    /// a full hour of repeats fits in iOS's 64 pending notifications (30 + 12 for missed readings).
    public static let urgentLowRepeatMinutes: ClosedRange<Int> = 2...5
    public static let urgentLowDefaultRepeatMinutes = 5
    /// Urgent-low repeats (pending notifications, and system alarms on iOS 26+) are scheduled this
    /// far ahead, whatever the repeat interval, so they keep coming for an hour with no wake-up.
    public static let urgentLowPendingHorizonMinutes = 60

    // MARK: Urgent low soon

    /// HANDOFF §5: "projected ≤ 55 within 20 min using the sensor's reported trend rate".
    /// The projection target is the urgent-low threshold.
    public static let urgentLowSoonHorizonMinutes = 20
    public static let urgentLowSoonDefaultSnoozeMinutes = 15

    // MARK: Low / high

    public static let lowThresholdMgdl: ClosedRange<Int> = 60...100
    public static let lowDefaultThresholdMgdl = 70
    public static let lowDefaultSnoozeMinutes = 30

    public static let highThresholdMgdl: ClosedRange<Int> = 120...400
    public static let highDefaultThresholdMgdl = 250
    public static let highDefaultSnoozeMinutes = 120
    /// "Fire only after N min above". 0 = fire on the first reading at or above the threshold.
    public static let highDelayMinutes: ClosedRange<Int> = 0...120
    public static let highDefaultDelayMinutes = 0

    // MARK: Rate

    /// mg/dL per minute, applied to the sensor-reported rate.
    public static let rateThresholdMgdlPerMinute: ClosedRange<Double> = 2.0...5.0
    public static let rateDefaultThresholdMgdlPerMinute = 3.0
    public static let rateDefaultSnoozeMinutes = 30

    // MARK: Missed readings (S5)

    /// HANDOFF §5: window 10–60 minutes, default 15.
    public static let missedReadingsWindowMinutes: ClosedRange<Int> = 10...60
    public static let missedReadingsDefaultWindowMinutes = 15
    public static let missedReadingsDefaultSnoozeMinutes = 30

    // MARK: Status alerts

    public static let sensorProblemDefaultSnoozeMinutes = 120
    /// Calibration needed: readings are withheld until the user acts, so remind every 30 minutes.
    public static let calibrationDefaultSnoozeMinutes = 30
    public static let bluetoothDefaultSnoozeMinutes = 30
    public static let trioBridgeDefaultSnoozeMinutes = 30
    /// HANDOFF §5: "Trio not consuming for 15 min".
    public static let trioNotConsumingMinutes = 15

    // MARK: Snooze for every alert other than urgent low

    public static let snoozeMinutes: ClosedRange<Int> = 5...(24 * 60)

    // MARK: Engine constants (not user-configurable)

    /// A reading counts as *current* for glucose alerts only while it is at most this old. After
    /// that its value is never evaluated again (S1: no carrying forward). 6 minutes follows Loop's
    /// stale-sample guard (LoopKit/Loop next-dev, Loop/Managers/Alerts/GlucoseAlertManager.swift:584);
    /// the G7 sends a reading every 5 minutes.
    public static let currentReadingMaximumAge: TimeInterval = 6 * 60

    /// Hysteresis: a glucose alert clears only once the value is this far back across the
    /// threshold, so a value hovering at the threshold does not fire, clear and fire again.
    /// 5 mg/dL follows Loop (GlucoseAlertManager.swift:95, `recoveryMarginMgDL: 5`).
    public static let glucoseRecoveryMarginMgdl = 5
    /// The same idea for rate alerts, in mg/dL per minute (this project's choice).
    public static let rateRecoveryMarginMgdlPerMinute = 1.0

    /// How many missed-readings notifications are scheduled ahead (≥ 2 hours at the 10-minute
    /// minimum window). iOS keeps at most 64 pending requests per app.
    public static let scheduledNotificationCount = 12
    /// The most future pending entries any alert keeps: urgent low at the 2-minute floor over 60
    /// minutes.
    public static let maximumScheduledSlots = urgentLowPendingHorizonMinutes / urgentLowRepeatMinutes.lowerBound
    /// Pending notifications and alarms are identified by their sequence number modulo this cycle
    /// (`ScheduledRepeat.slot`). The engine remembers entries for `seriesMemory` (at most 30 future
    /// + 30 past at the 2-minute floor), so an ID is reused only long after its entry is gone.
    public static let scheduleIDCycle = 128
    /// Pending entries older than this are forgotten (their notification has been delivered and
    /// their alarm has rung); `.cancel` still removes every identifier in the cycle.
    public static let seriesMemory: TimeInterval = 60 * 60
    /// Pending notifications and alarms due within this long (or already due) are never cancelled
    /// or replaced by a reschedule: one may be about to ring, or ringing (safety review WS4 B2).
    public static let protectedLeadTime: TimeInterval = 60
    /// A wake-up this early for a repeat slot still plays that slot's sound. The G7 wakes the app
    /// every ~5 minutes and the repeat grid is anchored at such a wake, so the next wake often
    /// lands a few seconds before the slot; without this the sound would slip a whole cycle.
    /// Must not exceed `LiveReadingGate.futureTolerance` (the clock-fault repair allows state
    /// dates up to that far ahead of now).
    public static let repeatSlotEarlyTolerance: TimeInterval = 60

    /// How long the in-app (ringer-off) audio loops for urgent low before stopping on its own. The
    /// next repeat plays it again. Other alerts play their sound once.
    public static let urgentInAppAudioSeconds: TimeInterval = 30

    /// Output volume (0…1) below which the Settings screen warns that ringer-off alarms may be too
    /// quiet to hear. A heuristic, not a measurement of loudness.
    public static let lowAlarmVolume: Float = 0.25

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
