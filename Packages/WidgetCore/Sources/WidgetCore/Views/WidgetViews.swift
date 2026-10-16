// Widget layouts (HANDOFF §7.4). They live in WidgetCore, free of WidgetKit, so the app's tests
// can render them for docs/screenshots; the extension wraps them with WidgetKit chrome.
//
// Every view displays one `WidgetEntryContent`. A number only from `content.widgetReading` (D61):
//   current       ink / band colour, trend arrow, delta, live age
//   stale         muted, no arrow, no delta, "STALE · 12 min ago" in the alert colour
//   last reading  muted, no arrow, no delta, "LAST READING" + its time + live age in the alert
//                 colour; the chart ends at that reading
// and a message otherwise. Nothing here computes a value (S1). Ages are live relative text
// (`LiveAge`), so they count up between timeline entries.

import GlucoseCore
import SwiftUI

// MARK: - Medium (priority: the owner's daily view)

public struct MediumWidgetView: View {
    public let content: WidgetEntryContent

    public init(content: WidgetEntryContent) {
        self.content = content
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 14) {
            WidgetReadingColumn(content: content, heroSize: 60)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                GlucoseTraceChart(
                    points: content.recent,
                    domain: content.chartDomain,
                    latestLive: WidgetStyle.chartLatest(content.display),
                    options: .widget,
                    accessibilityTitle: content.chartEndsAtReading ? "3 hours up to the last reading" : "Last 3 hours"
                )
                .opacity(WidgetStyle.chartOpacity(content.display))
                // D61: the chart ends at the last reading, not now; its right edge says when.
                if content.chartEndsAtReading, let shown = content.widgetReading, let day = content.readingDay {
                    ReadingTimeText.text(shown.reading.date, day: day)
                        .font(Typography.fixedLabel(size: 9))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .environment(\.accentChoice, content.accent)
    }
}

// MARK: - Small

public struct SmallWidgetView: View {
    public let content: WidgetEntryContent

    public init(content: WidgetEntryContent) {
        self.content = content
    }

    public var body: some View {
        WidgetReadingColumn(content: content, heroSize: 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .environment(\.accentChoice, content.accent)
    }
}

// MARK: - Lock Screen rectangular

public struct RectangularAccessoryView: View {
    public let content: WidgetEntryContent

    public init(content: WidgetEntryContent) {
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                if let shown = content.widgetReading {
                    reading(shown)
                } else {
                    Text(verbatim: WidgetStyle.title(content.display))
                        .font(Typography.body(size: 13, weight: .semibold))
                        .lineLimit(1)
                    WidgetDetailText(content: content, fontSize: 10)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if content.widgetReading != nil {
                // Too small for a time label: the text beside it gives the last reading's time.
                GlucoseTraceChart(
                    points: content.recent,
                    domain: content.chartDomain,
                    latestLive: nil,
                    options: .sparkline,
                    accessibilityTitle: content.chartEndsAtReading ? "3 hours up to the last reading" : "Last 3 hours"
                )
                .opacity(WidgetStyle.chartOpacity(content.display))
                .frame(width: 64)
            }
        }
    }

    @ViewBuilder
    private func reading(_ shown: WidgetReading) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: GlucoseText.value(shown.reading.value))
                // Smaller when a last reading from another day needs a fourth line (its age).
                .font(Typography.figure(size: shown.age == .last && content.readingDay != .sameDay ? 22 : 26))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let trend = shown.trend {
                TrendArrowView(arrow: trend, size: 14, lineWidth: 1.5)
            }
            // DEBUG: beside an old number (it has no arrow), so the label line below keeps its room.
            if shown.isMuted { ReplayMarker(content: content, fontSize: 10) }
        }
        // Lock Screen colours are the system's; secondary is its dimmed style.
        .foregroundStyle(shown.isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.isMuted && content.showsReplayMarker
                            ? Text("Replay, not the sensor. \(WidgetStyle.spokenText(shown, day: content.readingDay))")
                            : WidgetStyle.spokenText(shown, day: content.readingDay))
        HStack(spacing: 4) {
            if !shown.isMuted { ReplayMarker(content: content, fontSize: 10) }
            switch shown.age {
            case .current:
                RelativeAgeText(since: shown.reading.date)
                    .font(Typography.fixedLabel(size: 10))
            case .stale:
                Text("STALE · \(LiveAge.text(since: shown.reading.date, style: .short))")
                    .font(Typography.fixedLabel(size: 10, medium: true))
            case .last:
                Text(verbatim: WidgetStyle.lastReadingLabel)
                    .font(Typography.fixedLabel(size: 10, medium: true))
                    .accessibilityHidden(true)
            }
        }
        if shown.age == .last {
            LastReadingTimeLines(date: shown.reading.date, day: content.readingDay ?? .sameDay, ageStyle: .short)
                .font(Typography.fixedLabel(size: 10))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Lock Screen inline

public enum InlineAccessoryText {
    /// "105 → · 3m", "Stale 105 · 12m", "Last 105 · 2:14 PM" and short messages. Inline widgets
    /// show a single line of text only.
    public static func text(_ content: WidgetEntryContent) -> Text {
        if content.showsReplayMarker {
            return Text(verbatim: "\(WidgetStyle.replayLabel) ") + valueText(content)
        }
        return valueText(content)
    }

    private static func valueText(_ content: WidgetEntryContent) -> Text {
        if let shown = content.widgetReading {
            switch shown.age {
            case .current:
                return Text("\(inlineValue(shown)) · \(LiveAge.text(since: shown.reading.date, style: .short))")
            case .stale:
                return Text("Stale \(inlineValue(shown)) · \(LiveAge.text(since: shown.reading.date, style: .short))")
            case .last:
                let time = ReadingTimeText.text(shown.reading.date, day: content.readingDay ?? .sameDay)
                return Text("Last \(inlineValue(shown)) · \(time)")
            }
        }
        switch content.display {
        case .noData:
            return Text("No glucose data")
        case .warmingUp(let endsAt):
            return Text("Warming up · ready \(endsAt, style: .time)")
        case .sensorExpired:
            return Text("Sensor expired")
        case .sensorError:
            return Text("Sensor error")
        case .sensorFailed, .calibrationNeeded, .calibrationRejected:
            return Text(verbatim: WidgetStyle.title(content.display))
        case .notPaired:
            return Text("No sensor paired")
        case .clockMismatch:
            return Text("Check phone clock")
        case .current, .stale:
            // Unreachable: these always have a `widgetReading`.
            return Text("No glucose data")
        }
    }

    /// "105 →" while current; just "105" (or "LOW"/"HIGH") once it is not (no arrow, D61).
    static func inlineValue(_ shown: WidgetReading) -> String {
        let value = GlucoseText.value(shown.reading.value)
        guard let trend = shown.trend else { return value }
        let glyph = TrendText.glyph(trend)
        return glyph.isEmpty ? value : "\(value) \(glyph)"
    }
}

// MARK: - Shared pieces

/// Left side of the medium widget; all of the small widget.
struct WidgetReadingColumn: View {
    let content: WidgetEntryContent
    let heroSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let shown = content.widgetReading {
                // A last reading's element also speaks its time and age ("Last reading 112
                // milligrams per deciliter at 2:14 PM, 47 min ago"); its label lines are hidden.
                number(shown)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(WidgetStyle.spokenText(shown, day: content.readingDay))
                caption(shown)
            } else {
                Text(verbatim: WidgetStyle.title(content.display))
                    .font(Typography.figure(size: 24))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                WidgetDetailText(content: content, fontSize: 11)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3)
            }
        }
    }

    private func number(_ shown: WidgetReading) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Text(verbatim: GlucoseText.value(shown.reading.value))
                .font(Typography.heroNumeral(size: shown.reading.value.numericMgdl == nil ? heroSize * 0.62 : heroSize))
                .heroForeground(shown.isMuted ? nil : WidgetStyle.heroStyle(shown.reading.value), fallback: shown.isMuted ? .muted : .ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let trend = shown.trend {
                TrendArrowView(arrow: trend, size: 22, lineWidth: 1.8)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    /// Unit (or flag caption), delta, replay marker and the age line, under the number.
    @ViewBuilder
    private func caption(_ shown: WidgetReading) -> some View {
        Text(verbatim: GlucoseText.flagCaption(shown.reading.value) ?? GlucoseText.unit)
            .font(Typography.fixedLabel(size: 10))
            .foregroundStyle(Theme.ink)
        if let delta = shown.delta {
            Text(verbatim: DeltaText.text(delta))
                .font(Typography.fixedLabel(size: 10))
                .foregroundStyle(Theme.muted)
                .accessibilityLabel(Text(DeltaText.spoken(delta)))
        }
        ReplayMarker(content: content, fontSize: 10)
            .foregroundStyle(Theme.alert)
        switch shown.age {
        case .current:
            RelativeAgeText(since: shown.reading.date)
                .font(Typography.fixedLabel(size: 10))
                .foregroundStyle(Theme.muted)
        case .stale:
            Text("STALE · \(LiveAge.text(since: shown.reading.date)) ago")
                .font(Typography.fixedLabel(size: 10, medium: true))
                .foregroundStyle(Theme.alert)
        case .last:
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: WidgetStyle.lastReadingLabel)
                    .font(Typography.fixedLabel(size: 10, medium: true))
                LastReadingTimeLines(date: shown.reading.date, day: content.readingDay ?? .sameDay, ageStyle: .long)
                    .font(Typography.fixedLabel(size: 10))
            }
            .foregroundStyle(Theme.alert)
            .accessibilityHidden(true)
        }
    }
}

/// A last reading's time and live age (D61): "2:14 PM · 47 min ago" ("2:14 PM · 47m" on the Lock
/// Screen) on one line; with a day ("Yesterday 11:02 PM", "Sep 21 11:02 PM") the age goes on a
/// second line ("12 hr, 13 min ago"), so neither is cut off.
struct LastReadingTimeLines: View {
    let date: Date
    let day: ReadingDay
    let ageStyle: LiveAge.Style

    var body: some View {
        let time = ReadingTimeText.text(date, day: day)
        let age = LiveAge.text(since: date, style: ageStyle)
        if day == .sameDay {
            Group {
                if ageStyle == .long {
                    Text("\(time) · \(age) ago")
                } else {
                    Text("\(time) · \(age)")
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                time.lineLimit(1).minimumScaleFactor(0.8)
                Text("\(age) ago").lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}

/// DEBUG (audit m9): "REPLAY" beside a replayed reading (`WidgetEntryContent.showsReplayMarker`).
/// Draws nothing in Release.
struct ReplayMarker: View {
    let content: WidgetEntryContent
    let fontSize: CGFloat

    var body: some View {
        #if DEBUG
        if content.showsReplayMarker {
            Text(verbatim: WidgetStyle.replayLabel)
                .font(Typography.fixedLabel(size: fontSize, medium: true))
                .accessibilityLabel(Text(verbatim: "Replay, not the sensor"))
        }
        #endif
    }
}

/// Second line of a message state: what happened and what to do.
struct WidgetDetailText: View {
    let content: WidgetEntryContent
    let fontSize: CGFloat

    var body: some View {
        Group {
            switch content.display {
            case .noData:
                // Only without a reading to show: a reading ≥ 20 min old is a last reading (D61).
                if content.hidesEarlierSensorReading {
                    Text(verbatim: "No readings from the new sensor yet")
                } else {
                    Text(verbatim: "Open the app to check the sensor")
                }
            case .warmingUp(let endsAt):
                Text("Ready at \(endsAt, style: .time)")
            case .sensorExpired:
                Text(verbatim: "Start a new sensor")
            case .sensorError(let message, _):
                Text(verbatim: message)
            case .sensorFailed(let failure, _):
                Text(verbatim: failure.message)
            case .calibrationNeeded:
                Text(verbatim: "Enter a fingerstick in the app")
            case .calibrationRejected:
                Text(verbatim: "Enter a new fingerstick in the app")
            case .notPaired:
                Text(verbatim: "Pair a sensor in the app")
            case .clockMismatch:
                Text(verbatim: "The latest reading's time doesn't match this phone's clock")
            case .current, .stale:
                EmptyView()
            }
        }
        .font(Typography.body(size: fontSize))
    }
}

/// Small shared rules for the widget layouts. Pure; unit-tested.
public enum WidgetStyle {
    /// DEBUG (audit m9): the label on a replayed reading.
    public static let replayLabel = "REPLAY"

    /// D61: the label on a reading 20 min old or older, above its time and age.
    public static let lastReadingLabel = "LAST READING"

    /// A stale number is drawn in the muted colour (not faded by opacity, which would drop it
    /// below 3:1), next to a "STALE · 12 min ago" label, so an old number never looks current.
    public static func isStale(_ display: GlucoseDisplayState) -> Bool {
        if case .stale = display { return true }
        return false
    }

    /// Charts are dimmed whenever the number is not current (`Emphasis.dimmedChartOpacity`).
    public static func chartOpacity(_ display: GlucoseDisplayState) -> Double {
        if case .current = display { return 1 }
        return Emphasis.dimmedChartOpacity
    }

    /// The accent "latest" dot only while the reading is current.
    public static func chartLatest(_ display: GlucoseDisplayState) -> ChartPoint? {
        guard case .current(let reading) = display else { return nil }
        return ChartPoint(date: reading.date, value: reading.value)
    }

    /// Headline for message states.
    public static func title(_ display: GlucoseDisplayState) -> String {
        switch display {
        case .current(let reading), .stale(let reading): return GlucoseText.value(reading.value)
        case .noData: return "No data"
        case .warmingUp: return "Warming up"
        case .sensorExpired: return "Sensor expired"
        case .sensorError: return "Sensor error"
        case .sensorFailed(let failure, _):
            if failure.requiresPairing { return "Pair again" }
            if failure.requiresSensorReplacement { return "Replace sensor" }
            return "Sensor problem"
        case .calibrationNeeded: return "Calibrate sensor"
        case .calibrationRejected: return "Calibration not accepted"
        case .notPaired: return "No sensor"
        case .clockMismatch: return "Check phone clock"
        }
    }

    /// Ink when in range; the band colour otherwise (all band colours are ≥ 3:1 for large text).
    public static func heroStyle(_ value: GlucoseValue) -> BandStyle? {
        value.band == .inRange ? nil : Theme.band(value.band)
    }

    /// VoiceOver for the number:
    ///   current  "105 milligrams per deciliter, steady" (the age is read from the live text)
    ///   stale    "Stale: 105 milligrams per deciliter" (no trend word: no arrow either, D61)
    ///   last     "Last reading 105 milligrams per deciliter" (`spokenText` adds time and age)
    public static func spokenValue(_ shown: WidgetReading) -> String {
        let value = GlucoseText.spoken(shown.reading.value)
        switch shown.age {
        case .current: return "\(value), \(TrendText.word(shown.reading.trend))"
        case .stale: return "Stale: \(value)"
        case .last: return "Last reading \(value)"
        }
    }

    /// `spokenValue`, and for a last reading also its time and live age: "Last reading 112
    /// milligrams per deciliter at 2:14 PM, 47 min ago".
    public static func spokenText(_ shown: WidgetReading, day: ReadingDay?) -> Text {
        let value = Text(verbatim: spokenValue(shown))
        guard shown.age == .last else { return value }
        let date = shown.reading.date
        return Text("\(value) \(ReadingTimeText.spoken(date, day: day ?? .sameDay)), \(LiveAge.agoText(since: date))")
    }
}

public enum HeroFallback: Sendable {
    case ink, muted
}

extension View {
    /// The hero number's colour: `style`, or the `fallback` token (ink by default) when nil.
    @ViewBuilder
    public func heroForeground(_ style: BandStyle?, fallback: HeroFallback = .ink) -> some View {
        if let style {
            foregroundStyle(style)
        } else {
            switch fallback {
            case .ink: foregroundStyle(Theme.ink)
            case .muted: foregroundStyle(Theme.muted)
            }
        }
    }
}
