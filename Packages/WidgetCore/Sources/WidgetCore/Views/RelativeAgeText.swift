// A reading's age as text that the system keeps counting up without the widget being reloaded
// (HANDOFF §7.4: "render the age with a relative date so it keeps counting up").
//
// iOS 18+: whole minutes, rounded down ("3 min ago", "1 hr, 5 min ago"), the same rule as
// `AgeText` and the 10/20-minute thresholds. iOS 17 only has the seconds-counting relative style
// ("3 min, 12 sec ago"); still correct, just busier.

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
                allowedUnits: [.hours, .minutes],
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
