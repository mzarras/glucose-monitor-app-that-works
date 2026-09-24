// Axis choices for glucose charts. Pure; unit-tested.

import Foundation
import GlucoseCore

public enum ChartScale {
    /// Bottom of the y axis. This is the axis domain, not a value: LOW flags are never plotted at
    /// it (they are drawn as "LOW" markers in an overlay, S4).
    public static let yLowerBound = 40

    /// Top of the y axis: 250 (as in the mockup) unless a plotted value needs more room, then the
    /// next multiple of 50 above it, at most 400 (the sensor's top numeric value).
    public static func yUpperBound(maxPlotted: Int?) -> Int {
        guard let maxPlotted, maxPlotted + 10 > 250 else { return 250 }
        let rounded = Int((Double(maxPlotted + 10) / 50).rounded(.up)) * 50
        return min(400, rounded)
    }

    /// Y-axis labels: the target band edges, plus the top of the axis.
    public static func yAxisLabels(upperBound: Int) -> [Int] {
        [GlucoseThresholds.lowBelow, GlucoseThresholds.inRangeUpperBound, upperBound]
    }
}

public enum HourLabel {
    /// "12a", "6a", "10a", "12p", "1p" as in the mockups.
    public static func text(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        return text(hourOfDay: hour)
    }

    /// Same, for an hour of day 0...24 (24 reads as "12a", the end of the day).
    public static func text(hourOfDay: Int) -> String {
        let hour = ((hourOfDay % 24) + 24) % 24
        let suffix = hour < 12 ? "a" : "p"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve)\(suffix)"
    }
}

/// A fingerstick (calibration) value to mark on a chart. Deliberately not a `ChartPoint`: it is
/// drawn as a separate marker, never joined to the sensor line, never counted as a reading (S1).
public struct FingerstickMarker: Sendable, Equatable, Hashable, Codable {
    public let date: Date
    public let mgdl: Int

    public init(date: Date, mgdl: Int) {
        self.date = date
        self.mgdl = mgdl
    }
}
