// The pipeline's widget output: `WidgetSnapshotPublisher` (App Group file + WidgetKit reload) with
// the user's accent. A write failure is a diagnostic; the widget then keeps showing its previous
// snapshot, whose own timeline turns it stale and then into a last reading on time (docs/widgets.md, S5).
//
// D61 reload policy: the pipeline publishes on every drain (several per 5-minute wake), and iOS
// budgets background widget reloads (roughly 40–70 a day). So the snapshot is written every time,
// but a reload is requested only when `WidgetReloadKey` — what the widget would display — differs
// from the last snapshot a reload was requested for. The first publish of the process, and the
// first after the app comes to the foreground (`reloadOnNextPublish`; foreground reloads are not
// budgeted), always reloads. Each requested reload is one diagnostic line; skipped ones are not
// logged (they happen several times per wake).

import Foundation
import GlucoseCore
import WidgetCore

@MainActor
final class LiveWidgetPublisher: WidgetSnapshotPublishing {
    private let publisher: WidgetSnapshotPublisher
    private let diagnostics: any DiagnosticLog
    var accent: AccentChoice
    /// The key of the last snapshot a reload was requested for; nil: none yet (reload next time).
    private(set) var lastReloadKey: WidgetReloadKey?
    /// Review m4: the phone's time zone and locale identifiers, read at every publish (replaced in tests).
    private let zoneAndLocale: @MainActor () -> (timeZoneID: String, localeID: String)

    init(publisher: WidgetSnapshotPublisher, accent: AccentChoice, diagnostics: any DiagnosticLog,
         zoneAndLocale: @escaping @MainActor () -> (timeZoneID: String, localeID: String) = { (TimeZone.current.identifier, Locale.current.identifier) }) {
        self.publisher = publisher
        self.accent = accent
        self.diagnostics = diagnostics
        self.zoneAndLocale = zoneAndLocale
    }

    func publish(latestLive: GlucoseReading?, previousLive: GlucoseReading?, recent: [GlucoseReading], sensorState: SensorState,
                 currentSensor: WidgetCurrentSensor?, now: Date) {
        let snapshot: WidgetSnapshot
        do {
            snapshot = try publisher.write(latestLive: latestLive, previousLive: previousLive, recent: recent, sensorState: sensorState,
                                           currentSensor: currentSensor, accent: accent, now: now)
        } catch {
            diagnostics.record(DiagnosticEvent(date: now, category: .app, message: "widget snapshot write failed: \(error)"))
            return
        }
        let environment = zoneAndLocale()
        let key = WidgetReloadKey(snapshot, timeZoneID: environment.timeZoneID, localeID: environment.localeID)
        guard let reason = WidgetReloadKey.reloadReason(previous: lastReloadKey, current: key) else { return }
        publisher.reloadTimelines()
        lastReloadKey = key
        diagnostics.record(DiagnosticEvent(date: now, category: .app, message: "widget reload requested: \(reason.logText)"))
    }

    /// The next publish reloads whatever it writes (the app came to the foreground).
    func reloadOnNextPublish() {
        lastReloadKey = nil
    }
}
