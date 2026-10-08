// Every question the Predict tab asks about a model run's age, in one place (PROGRESS D57, D59;
// docs/forecast.md "Freshness"). The 15-minute rule is ForecastKit's: a run's age is the larger of
// its age by the phone's clock and its age on arrival plus the real (monotonic) time since, so
// setting the clock back never makes an old run look current. This file only asks ForecastKit, at
// one `ForecastInstant` of the UI clock, and is the only app code that asks about the Zen run.

import ForecastKit
import Foundation

/// The clock the Predict tab is drawn for: the phone's wall clock and a monotonic clock read
/// together (`ForecastInstant`). An app type, so `AppModel.swift` needs no ForecastKit import.
struct PredictClock {
    let read: @MainActor () -> ForecastInstant

    /// The phone: `ForecastInstant.now()` (also in a DEBUG replay run: the feed is real time).
    static var phone: PredictClock {
        PredictClock { ForecastInstant.now() }
    }

    #if DEBUG
    /// Tests only: an injected wall clock, with a monotonic reading that follows it (only for
    /// clocks that move forward). Never in Release: a wall-only clock would lose D59's protection
    /// against the phone's clock being set back.
    static func following(_ wall: @escaping @MainActor () -> Date) -> PredictClock {
        PredictClock {
            let date = wall()
            return ForecastInstant(wall: date, monotonic: date.timeIntervalSince1970)
        }
    }
    #endif
}

enum PredictFreshness {
    /// The Zen run's time (the CGM reading it ran on), nil when the feed has no run.
    static func runTime(_ latest: LatestForecast) -> Date? {
        latest.zenRunTime
    }

    /// Whether the Zen run may be shown at `instant`, nil when the feed has no run.
    static func freshness(_ latest: LatestForecast, at instant: ForecastInstant) -> ForecastFreshness? {
        latest.zenFreshness(at: instant)
    }

    /// The run, only if it may be shown as the current forecast at `instant` (≤ 15 min old by both
    /// clocks, not ahead of the phone's clock). The only way the Predict tab gets points to draw.
    static func currentRun(_ latest: LatestForecast, at instant: ForecastInstant) -> ForecastRun? {
        latest.currentRun(at: instant)
    }

    /// The run's conservative age at `instant` for "MODEL RAN 12:32 PM · 3 MIN AGO" and "last model run 32 min
    /// ago" (never negative, never lowered by a clock set back); nil without a run.
    static func runAge(_ latest: LatestForecast, at instant: ForecastInstant) -> TimeInterval? {
        latest.zenRunAge(at: instant)
    }

    /// When the screen should look again: one second after the run's conservative age passes
    /// `ForecastLimits.staleAfter`, on the wall clock, rounded up to a whole second (so it does not
    /// move from tick to tick). Only a redraw hint; the UI tick re-evaluates every 15 s regardless.
    static func redrawDate(_ latest: LatestForecast, at instant: ForecastInstant) -> Date? {
        guard let age = runAge(latest, at: instant) else { return nil }
        let at = instant.wall.addingTimeInterval(ForecastLimits.staleAfter - age + 1)
        return Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.up))
    }
}
