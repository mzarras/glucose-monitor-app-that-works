// Original to Sensor (no ported code).
// Every number ForecastKit judges the feed by, in one place (S8). docs/forecast.md explains each.

import Foundation

public enum ForecastLimits {
    /// A Zen run older than this (measured from `generatedAt`) is stale and must not be shown as the
    /// current forecast (PROGRESS D57). Equal to the predict Lambda's own `STALE_CGM_MINUTES = 15.0`
    /// (zen-predict-infra lambdas/handlers/predict.py:55 @ 3f3d682), above which it makes no run.
    public static let staleAfter: TimeInterval = 15 * 60

    /// How far ahead of the phone's clock a feed timestamp may be before the document is rejected.
    ///
    /// The feed's times come from other clocks: `as_of` from the Lambda, `generated_at` and `bg.ts`
    /// from whichever device uploaded the reading to Nightscout. NTP-synced clocks agree to well
    /// under a second, so 2 minutes only absorbs a badly set clock, while staying under one CGM
    /// interval (5 min). (The app's own live-reading gate allows 60 s, but there both times come
    /// from this phone.)
    ///
    /// What this bounds: if the phone's clock was right when the document arrived, a run can look
    /// up to 2 minutes younger than it is (an uploader clock up to 2 minutes fast), so it can stay
    /// current up to 2 minutes beyond the 15-minute rule. Changing the phone's clock after the
    /// document arrived does not extend that (`ForecastFreshness` adds the monotonic time since
    /// arrival). A phone clock that was already slow when the document arrived does: by as much as
    /// it was slow, as long as the run still passed the future-dated check. Nothing in the feed can
    /// detect that; it is the same limit the app's live readings have.
    public static let clockSkewTolerance: TimeInterval = 2 * 60

    /// Any non-null Zen value outside this range rejects the whole document.
    ///
    /// The model clips every output to 40…400 mg/dL (zen-predict @ 0d13ce3 zen_predict/model.py:34-35
    /// `BG_FLOOR`/`BG_CEIL`, `_clip` at :54-55), so a value outside 40…400 already means the clip
    /// was bypassed. The margin keeps a deliberate change of the clip from breaking the app, while
    /// 20…600 is still the measuring range of a blood glucose meter (e.g. Contour Next One), so a
    /// value outside it is not glucose at all. It also catches unit faults: an mmol/L value below
    /// 20 (anything under 360 mg/dL) and a doubled mg/dL conversion (40 × 18 = 720 > 600).
    public static let plausibleZenMgdl: ClosedRange<Double> = 20...600

    /// The Zen model's output clip, 40…400 mg/dL (zen-predict @ 0d13ce3 zen_predict/model.py:34-35
    /// `BG_FLOOR = 40.0`, `BG_CEIL = 400.0`). `ForecastPoint.modelBound` reports values at or
    /// beyond these edges as bounds ("≤40", "≥400"), never as plain numbers (PROGRESS D58 (4)).
    static let zenModelClip: ClosedRange<Double> = 40...400

    /// Any non-null oref value outside this range rejects the whole document.
    ///
    /// Exactly oref's own clamps: Trio's determine-basal clamps the IOB, ZT and UAM predBG curves to
    /// 39…401 and the COB curve to 39…1500 (vendor-ref Trio trio-oref/lib/determine-basal/
    /// determine-basal.js:995, 1005, 1016, 1030). The feed's value is the median of the curves
    /// present at that step (zen_predict/oref_points.py `median_curve`), which at long horizons can
    /// be the COB curve alone, so up to 1500 is a genuine oref output, not a fault.
    public static let plausibleOrefMgdl: ClosedRange<Double> = 39...1500

    /// Any published `bg.mg_dl` outside this range rejects the whole document. Same bound as
    /// NightscoutKit's `NightscoutGlucoseEncoding.maximumPlausibleSGV`: no CGM reports beyond
    /// ~600 mg/dL; 0…38 are Dexcom error codes (classified, not rejected).
    public static let plausibleFeedGlucose: ClosedRange<Double> = 0...1000

    /// A published mean absolute error (`mae`, `persistence_mae`) outside this range rejects the
    /// whole metrics document: an average miss cannot exceed the widest Zen forecast range.
    public static let plausibleMeanAbsoluteErrorMgdl: ClosedRange<Double> = 0...600

    /// `win_rate_vs_oref` is a fraction (publish.py `_window_stats`: wins / n_vs_oref).
    public static let plausibleWinRate: ClosedRange<Double> = 0...1

    /// `parkes_ab_pct` is a percentage (publish.py `_window_stats`: 100 × weighted A+B fraction).
    public static let plausiblePercent: ClosedRange<Double> = 0...100

    /// A response body larger than this is refused as a transport error before it is decoded.
    /// The real documents are tiny (captured 2026-10-08: latest.json 328 and 330 bytes,
    /// metrics.json 541 bytes), so 512 KiB is about a thousand times the largest and leaves room
    /// for the producer to grow, while a wrong host serving a large file costs little memory.
    static let maximumResponseBytes = 512 * 1024
}
