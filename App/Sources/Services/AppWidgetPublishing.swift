// The widget output as LiveAppServices sees it: the pipeline's `WidgetSnapshotPublishing` plus the
// accent the snapshot carries. `LiveWidgetPublisher` is the production conformer; launch-order tests
// record snapshots instead.

import WidgetCore

@MainActor
protocol AppWidgetPublishing: WidgetSnapshotPublishing {
    var accent: AccentChoice { get set }
}

extension LiveWidgetPublisher: AppWidgetPublishing {}
