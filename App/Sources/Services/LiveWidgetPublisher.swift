// The pipeline's widget output: `WidgetSnapshotPublisher` (App Group file + WidgetKit reload) with
// the user's accent. A write failure is a diagnostic; the widget then keeps showing its previous
// snapshot, whose own timeline turns it stale and then "No data" on time (docs/widgets.md, S5).

import Foundation
import GlucoseCore
import WidgetCore

@MainActor
final class LiveWidgetPublisher: WidgetSnapshotPublishing {
    private let publisher: WidgetSnapshotPublisher
    private let diagnostics: any DiagnosticLog
    var accent: AccentChoice

    init(publisher: WidgetSnapshotPublisher, accent: AccentChoice, diagnostics: any DiagnosticLog) {
        self.publisher = publisher
        self.accent = accent
        self.diagnostics = diagnostics
    }

    func publish(latestLive: GlucoseReading?, previousLive: GlucoseReading?, recent: [GlucoseReading], sensorState: SensorState, now: Date) {
        do {
            try publisher.publish(latestLive: latestLive, previousLive: previousLive, recent: recent, sensorState: sensorState, accent: accent, now: now)
        } catch {
            diagnostics.record(DiagnosticEvent(date: now, category: .app, message: "widget snapshot write failed: \(error)"))
        }
    }
}
