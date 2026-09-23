// Widget layouts (HANDOFF §7.4). They live in WidgetCore, free of WidgetKit, so the app's tests
// can render them for docs/screenshots; the extension wraps them with WidgetKit chrome.
//
// Every view displays one `WidgetEntryContent`: a reading only in `.current` (and dimmed in
// `.stale`), a message otherwise. Nothing here computes a value (S1). Ages are live relative
// text (`RelativeAgeText`), so they count up between timeline entries.

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
            GlucoseTraceChart(
                points: content.recent,
                domain: content.date.addingTimeInterval(-WidgetSnapshot.historyWindow)...content.date,
                options: .widget,
                accessibilityTitle: "Last 3 hours"
            )
            .opacity(WidgetStyle.chartOpacity(content.display))
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
                switch content.display {
                case .current(let reading), .stale(let reading):
                    HStack(spacing: 3) {
                        Text(verbatim: GlucoseText.value(reading.value))
                            .font(Typography.figure(size: 26))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        TrendArrowView(arrow: reading.trend, size: 14, lineWidth: 1.5)
                    }
                    .opacity(WidgetStyle.numberOpacity(content.display))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(WidgetStyle.spokenValue(reading)))
                    if case .stale = content.display {
                        Text("STALE · \(LiveAge.text(since: reading.date, style: .short))")
                            .font(Typography.fixedLabel(size: 10, medium: true))
                    } else {
                        RelativeAgeText(since: reading.date)
                            .font(Typography.fixedLabel(size: 10))
                    }
                default:
                    Text(verbatim: WidgetStyle.title(content.display))
                        .font(Typography.body(size: 13, weight: .semibold))
                        .lineLimit(1)
                    WidgetDetailText(content: content, fontSize: 10)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if content.display.displayedReading != nil {
                GlucoseTraceChart(
                    points: content.recent,
                    domain: content.date.addingTimeInterval(-WidgetSnapshot.historyWindow)...content.date,
                    options: .sparkline,
                    accessibilityTitle: "Last 3 hours"
                )
                .opacity(WidgetStyle.chartOpacity(content.display))
                .frame(width: 64)
            }
        }
    }
}

// MARK: - Lock Screen inline

public enum InlineAccessoryText {
    /// "105 → · 3m" and short messages. Inline widgets show a single line of text only.
    public static func text(_ content: WidgetEntryContent) -> Text {
        switch content.display {
        case .current(let reading):
            let value = inlineValue(reading)
            return Text("\(value) · \(LiveAge.text(since: reading.date, style: .short))")
        case .stale(let reading):
            return Text("Stale \(inlineValue(reading)) · \(LiveAge.text(since: reading.date, style: .short))")
        case .noData(let last):
            if let last {
                return Text("No data · \(LiveAge.text(since: last.date, style: .short))")
            }
            return Text("No glucose data")
        case .warmingUp(let endsAt):
            return Text("Warming up · ready \(endsAt, style: .time)")
        case .sensorExpired:
            return Text("Sensor expired")
        case .sensorError:
            return Text("Sensor error")
        case .notPaired:
            return Text("No sensor paired")
        }
    }

    static func inlineValue(_ reading: LatestReading) -> String {
        let glyph = TrendText.glyph(reading.trend)
        let value = GlucoseText.value(reading.value)
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
            switch content.display {
            case .current(let reading), .stale(let reading):
                HStack(alignment: .center, spacing: 6) {
                    Text(verbatim: GlucoseText.value(reading.value))
                        .font(Typography.heroNumeral(size: reading.value.numericMgdl == nil ? heroSize * 0.62 : heroSize))
                        .heroForeground(WidgetStyle.heroStyle(reading.value))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    TrendArrowView(arrow: reading.trend, size: 22, lineWidth: 1.8)
                        .foregroundStyle(Theme.accent)
                }
                .opacity(WidgetStyle.numberOpacity(content.display))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(WidgetStyle.spokenValue(reading)))

                Text(verbatim: GlucoseText.flagCaption(reading.value) ?? GlucoseText.unit)
                    .font(Typography.fixedLabel(size: 10))
                    .foregroundStyle(Theme.ink)
                if let delta = reading.delta {
                    Text(verbatim: DeltaText.text(delta))
                        .font(Typography.fixedLabel(size: 10))
                        .foregroundStyle(Theme.muted)
                        .accessibilityLabel(Text(DeltaText.spoken(delta)))
                }
                if case .stale = content.display {
                    Text("STALE · \(LiveAge.text(since: reading.date)) ago")
                        .font(Typography.fixedLabel(size: 10, medium: true))
                        .foregroundStyle(Theme.alert)
                } else {
                    RelativeAgeText(since: reading.date)
                        .font(Typography.fixedLabel(size: 10))
                        .foregroundStyle(Theme.muted)
                }
            default:
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
}

/// Second line of a message state: what happened and, where useful, how old the last reading is.
struct WidgetDetailText: View {
    let content: WidgetEntryContent
    let fontSize: CGFloat

    var body: some View {
        Group {
            switch content.display {
            case .noData(let last):
                if let last {
                    Text("Last reading \(LiveAge.text(since: last.date)) ago")
                } else {
                    Text(verbatim: "Open the app to check the sensor")
                }
            case .warmingUp(let endsAt):
                Text("Ready at \(endsAt, style: .time)")
            case .sensorExpired:
                Text(verbatim: "Start a new sensor")
            case .sensorError(let message, _):
                Text(verbatim: message)
            case .notPaired:
                Text(verbatim: "Pair a sensor in the app")
            case .current, .stale:
                EmptyView()
            }
        }
        .font(Typography.body(size: fontSize))
    }
}

/// Small shared rules for the widget layouts. Pure; unit-tested.
public enum WidgetStyle {
    /// Stale readings are dimmed so an old number never looks current (HANDOFF §7.4).
    public static let staleOpacity: Double = 0.4

    public static func numberOpacity(_ display: GlucoseDisplayState) -> Double {
        if case .stale = display { return staleOpacity }
        return 1
    }

    public static func chartOpacity(_ display: GlucoseDisplayState) -> Double {
        if case .current = display { return 1 }
        return staleOpacity
    }

    /// Headline for message states.
    public static func title(_ display: GlucoseDisplayState) -> String {
        switch display {
        case .current(let reading), .stale(let reading): return GlucoseText.value(reading.value)
        case .noData: return "No data"
        case .warmingUp: return "Warming up"
        case .sensorExpired: return "Sensor expired"
        case .sensorError: return "Sensor error"
        case .notPaired: return "No sensor"
        }
    }

    /// Ink when in range; the band colour otherwise (all band colours are ≥ 3:1 for large text).
    public static func heroStyle(_ value: GlucoseValue) -> BandStyle? {
        value.band == .inRange ? nil : Theme.band(value.band)
    }

    /// "105 milligrams per deciliter, steady" (the age is read separately, from the live text).
    public static func spokenValue(_ reading: LatestReading) -> String {
        "\(GlucoseText.spoken(reading.value)), \(TrendText.word(reading.trend))"
    }
}

extension View {
    /// The hero number's colour: `style`, or the ink token when `style` is nil.
    @ViewBuilder
    public func heroForeground(_ style: BandStyle?) -> some View {
        if let style {
            foregroundStyle(style)
        } else {
            foregroundStyle(Theme.ink)
        }
    }
}
