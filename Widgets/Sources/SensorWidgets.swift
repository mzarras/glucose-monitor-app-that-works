// Phase 0 scaffold. WS5 replaces this with the widgets in HANDOFF §7.4.
import SwiftUI
import WidgetKit

@main
struct SensorWidgetBundle: WidgetBundle {
    var body: some Widget {
        ScaffoldWidget()
    }
}

struct ScaffoldWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "scaffold", provider: ScaffoldProvider()) { _ in
            Text(verbatim: "—").containerBackground(.background, for: .widget)
        }
        .supportedFamilies([.systemMedium])
    }
}

struct ScaffoldEntry: TimelineEntry {
    let date: Date
}

struct ScaffoldProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScaffoldEntry { ScaffoldEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping @Sendable (ScaffoldEntry) -> Void) {
        completion(ScaffoldEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ScaffoldEntry>) -> Void) {
        completion(Timeline(entries: [ScaffoldEntry(date: .now)], policy: .never))
    }
}
