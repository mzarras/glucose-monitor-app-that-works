// A reading's age as text that the system keeps counting up without the widget being reloaded
// (HANDOFF §7.4: "render the age with a relative date so it keeps counting up").
//
// iOS 18+: whole minutes, rounded down ("3 min ago", "1 hr, 5 min ago", "2 days, 3 hr ago" for a
// last reading days old, D61), the same rule as `AgeText` and the 10/20-minute thresholds. iOS 17
// only has the seconds-counting relative style ("3 min, 12 sec ago"); still correct, just busier.

import SwiftUI

public enum LiveAge {
    public enum Style: Sendable {
        /// "3 min" (callers add "ago")
        case long
        /// "3m" (inline Lock Screen widget)
        case short
    }

    /// Live-updating elapsed time since `date`, without "ago".
    public static func text(since date: Date, style: Style = .long) -> Text {
        if #available(iOS 18.0, macOS 15.0, *) {
            let format = Duration.UnitsFormatStyle(
                allowedUnits: [.days, .hours, .minutes],
                width: style == .long ? .abbreviated : .narrow,
                maximumUnitCount: 2,
                fractionalPart: .hide(rounded: .down)
            )
            return Text(.durationOffset(to: date), format: format)
        }
        return Text(date, style: .relative)
    }

    /// "3 min ago", live.
    public static func agoText(since date: Date) -> Text {
        Text("\(text(since: date)) ago")
    }
}

/// `LiveAge.agoText` as a view.
public struct RelativeAgeText: View {
    public let date: Date

    public init(since date: Date) {
        self.date = date
    }

    public var body: some View {
        LiveAge.agoText(since: date)
    }
}

/// A last reading's clock time (D61), with its day when that is not the entry's day. The system
/// time style, so a 24-hour locale shows "14:14". Static text: the day is fixed per timeline entry
/// (`WidgetEntryContent.readingDay`; the timeline has an entry at each midnight that changes it).
public enum ReadingTimeText {
    /// "2:14 PM", "Yesterday 11:02 PM", "Oct 14 9:30 AM".
    public static func text(_ date: Date, day: ReadingDay) -> Text {
        switch day {
        case .sameDay:
            return Text(date, style: .time)
        case .yesterday:
            return Text("Yesterday \(date, style: .time)")
        case .earlier:
            return Text("\(date.formatted(.dateTime.month(.abbreviated).day())) \(date, style: .time)")
        }
    }

    /// VoiceOver: "at 2:14 PM", "yesterday at 11:02 PM", "on Oct 14 at 9:30 AM".
    public static func spoken(_ date: Date, day: ReadingDay) -> Text {
        switch day {
        case .sameDay:
            return Text("at \(date, style: .time)")
        case .yesterday:
            return Text("yesterday at \(date, style: .time)")
        case .earlier:
            return Text("on \(date.formatted(.dateTime.month(.wide).day())) at \(date, style: .time)")
        }
    }
}
