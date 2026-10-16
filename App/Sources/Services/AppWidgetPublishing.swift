// The widget output as LiveAppServices sees it: the pipeline's `WidgetSnapshotPublishing` plus the
// accent the snapshot carries. `LiveWidgetPublisher` is the production conformer; launch-order tests
// record snapshots instead.

import WidgetCore

@MainActor
protocol AppWidgetPublishing: WidgetSnapshotPublishing {
    var accent: AccentChoice { get set }
    /// D61: the next publish asks WidgetKit to reload even if the widget's content is unchanged
    /// (called when the app comes to the foreground, where reloads are not budgeted).
    func reloadOnNextPublish()
}

extension LiveWidgetPublisher: AppWidgetPublishing {}
