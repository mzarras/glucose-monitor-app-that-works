// Everything the engine reacts to (HANDOFF §5, brief item 4). The engine is a pure function of
// these inputs and the time passed with each one; it performs no I/O.

import GlucoseCore

public enum AlertInput: Sendable, Equatable {
    /// A reading from the CGM pipeline and the session it was authenticated to. The engine runs
    /// `LiveReadingGate` on it first (S2, S6); a refused reading changes nothing — it can neither
    /// fire nor clear any alert, including missed readings.
    ///
    /// Feed only readings the store newly accepted (`GlucoseReadingRepository.insert` return
    /// value). Never feed history or the result of a store query: the engine must only ever see
    /// live readings (S6), and imported ones are refused here anyway.
    case reading(GlucoseReading, session: SensorSession?)
    /// A state change from the CGM source.
    case sensorState(SensorState)
    /// A status change from the Trio bridge.
    case trioBridge(TrioBridgeStatus)
    /// The reading store's health after each drain attempt (D42).
    case storage(StorageHealth)
    /// Time has passed. Send on every wake-up and about once a minute while the app is running;
    /// nothing is lost if ticks are late, because pending notifications cover the suspended app.
    case tick
    /// The app came to the foreground (send it when the scene becomes active). Writes the pending
    /// sensor expiry reminders again, adding any the system refused or dropped and refreshing their
    /// text for the current time zone (D43 review B1).
    case foreground
    /// Pending notifications the delivery layer could not add (e.g. notifications not allowed yet).
    /// `AlertService` sends this itself after each batch; the app never needs to (D43 review B1).
    case notificationsNotScheduled([AlertNotice])
    /// The app process started (first input after restoring the snapshot). Reconciles what a
    /// previous process left pending: urgent-low repeats (notifications and system alarms) are
    /// rebuilt if urgent low is firing and removed otherwise; missed-readings notifications are
    /// rebuilt. `AlertService.start()` sends it.
    case launched
    /// Something the user did in the app or on a notification.
    case user(AlertUserAction)
    /// The user changed alert settings.
    case settings(AlertSettings)
}

public enum AlertUserAction: Sendable, Equatable, Codable {
    /// "I've seen it": stops the sound and repeats and removes the notifications. The alert comes
    /// back after its snooze time if the condition is still true (urgent low: ≤ 30 minutes, S7).
    case acknowledge(AlertKind)
    /// Silence a firing alert for `minutes` (urgent low: clamped to ≤ 30, S7). Ignored unless the
    /// alert is firing or already snoozed: there is no pre-emptive snooze.
    case snooze(AlertKind, minutes: Int)
    /// The notification was swiped away: stop the in-app sound only. Repeats continue.
    case silence(AlertKind)
}
