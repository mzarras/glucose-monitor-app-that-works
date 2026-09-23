// Glucose Management Indicator. Bergenstal RM et al., "Glucose Management Indicator (GMI): A New
// Term for Estimating A1C From Continuous Glucose Monitoring", Diabetes Care 2018;41:2275–2280.

/// GMI (%) = 3.31 + 0.02392 × mean glucose (mg/dL) (Bergenstal et al. 2018).
///
/// The consensus recommends 14 days of CGM data (Battelino et al., Diabetes Care 2019;42:1593,
/// Table 2 item 1, "Number of Days CGM Worn (recommend 14 days)"), and the Trends screen shows GMI
/// only for 14 D and longer (HANDOFF §7.3 item 2). So `percent` is withheld (nil) below 14 calendar
/// days rather than left for the UI to hide: a short-period GMI cannot be displayed by mistake.
/// The 70 % data-sufficiency rule applies too but is not folded in here: `PeriodStatistics` carries
/// `gmi` next to `dataSufficiency`, and the UI should show the < 70 % warning beside the GMI row
/// (`dataSufficiency.isBelowWarningThreshold`), as HANDOFF §7.3 asks for every period.
public struct GlucoseManagementIndicator: Sendable, Equatable {
    /// Minimum period length, in local calendar days (see `CalendarDays`).
    public static let minimumCalendarDays = 14

    /// The period touches at least `minimumCalendarDays` calendar dates.
    public let isMeaningful: Bool
    /// GMI in percent (NGSP A1C units); `nil` when not meaningful or there is no mean.
    public let percent: Double?

    public init(meanMgdl: Double?, calendarDayCount: Int) {
        isMeaningful = calendarDayCount >= Self.minimumCalendarDays
        percent = isMeaningful ? meanMgdl.map(Self.percent(forMeanMgdl:)) : nil
    }

    /// The Bergenstal formula alone, for any mean in mg/dL.
    public static func percent(forMeanMgdl mean: Double) -> Double {
        3.31 + 0.02392 * mean
    }
}
