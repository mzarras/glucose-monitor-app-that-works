// Widget extension (HANDOFF §7.4): one "Glucose" widget in four families — medium (priority),
// small, Lock Screen rectangular and inline. Reads the snapshot the app writes to the App Group;
// never computes or guesses a value (S1). Stale and last-reading states (D61) are scheduled as future
// timeline entries (S5). Tapping opens the Now screen. Widgets always follow the system
// appearance.
//
// Layouts live in WidgetCore (MediumWidgetView etc.) so the app's tests can render them.

import SwiftUI
import WidgetCore
import WidgetKit

@main
struct SensorWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()
    }
}

struct GlucoseWidget: Widget {
    static let kind = "GlucoseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlucoseTimelineProvider()) { entry in
            GlucoseWidgetView(entry: entry)
        }
        .configurationDisplayName("Glucose")
        .description("Current reading, trend and the last three hours.")
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

struct GlucoseEntry: TimelineEntry {
    let date: Date
    let content: WidgetEntryContent

    init(_ content: WidgetEntryContent) {
        self.date = content.date
        self.content = content
    }
}

struct GlucoseTimelineProvider: TimelineProvider {
    /// Shown redacted while the widget loads. Carries no value (S1).
    func placeholder(in context: Context) -> GlucoseEntry {
        GlucoseEntry(WidgetTimeline.entries(snapshot: nil, now: Date())[0])
    }

    /// The widget gallery and transient views use the real snapshot too; with none, "No data".
    func getSnapshot(in context: Context, completion: @escaping @Sendable (GlucoseEntry) -> Void) {
        completion(GlucoseEntry(WidgetTimeline.entries(snapshot: SnapshotSource.read(), now: Date())[0]))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<GlucoseEntry>) -> Void) {
        let now = Date()
        let snapshot = SnapshotSource.read()
        // Review N1: a clock mismatch stays latched across reloads until a newer reading arrives.
        let latch = WidgetTimeline.clockMismatchLatch(snapshot: snapshot, now: now, previous: MismatchLatchStore.load())
        MismatchLatchStore.save(latch)
        let contents = WidgetTimeline.entries(snapshot: snapshot, now: now, latchedFor: latch)
        let reload = WidgetTimeline.nextReload(entries: contents, now: now)
        completion(Timeline(entries: contents.map(GlucoseEntry.init), policy: .after(reload)))
    }
}

/// Reads the app's snapshot through `WidgetSnapshotStore.snapshotForWidget()` (tested in
/// WidgetCore): any failure — no App Group, no file yet, empty, truncated or corrupt JSON, another
/// schema — reads as "no snapshot", which the timeline shows as "No data", never as a number.
enum SnapshotSource {
    static func read() -> WidgetSnapshot? {
        WidgetSnapshotStore.snapshotForWidget()
    }

    /// `<BUNDLE_ID_PREFIX>://now` (Widgets/Info.plist `HostAppURLScheme`; the app registers the
    /// same scheme in App/Info.plist CFBundleURLTypes).
    static var nowURL: URL? {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "HostAppURLScheme") as? String, !scheme.isEmpty else {
            return nil
        }
        return URL(string: "\(scheme)://now")
    }
}

/// The widget extension's own memory of a latched clock mismatch (the reading's date).
enum MismatchLatchStore {
    private static let key = "clockMismatchLatchedFor"

    static func load() -> Date? {
        let seconds = UserDefaults.standard.double(forKey: key)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    static func save(_ date: Date?) {
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlucoseEntry

    var body: some View {
        content
            .widgetURL(SnapshotSource.nowURL)
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(content: entry.content)
                .containerBackground(Theme.background, for: .widget)
        case .accessoryRectangular:
            RectangularAccessoryView(content: entry.content)
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryInline:
            InlineAccessoryText.text(entry.content)
                .containerBackground(for: .widget) { Color.clear }
        default:
            MediumWidgetView(content: entry.content)
                .containerBackground(Theme.background, for: .widget)
        }
    }
}
