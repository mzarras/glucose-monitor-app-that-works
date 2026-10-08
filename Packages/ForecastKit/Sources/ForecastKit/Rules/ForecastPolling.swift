// Original to Sensor (no ported code).
// When to fetch the feed. Pure functions: the app owns the timers, and fetches only while it is in
// the foreground (PROGRESS D57).
//
// Why these numbers (zen-predict-infra @ 3f3d682): a new run is published within seconds of the
// predict Lambda writing it (handlers/predict.py `_trigger_publish` invokes publish), predict runs
// every 5 minutes (terraform/main.tf `rate(5 minutes)`), and the 5-minute publish schedule is the
// fallback. CloudFront caches `*.json` for 30 s (terraform/cloudfront.tf
// `aws_cloudfront_cache_policy.json`: default_ttl 30, max_ttl 60; publish.py sends `max-age=30` for
// latest.json, `max-age=120` for metrics.json, so CloudFront keeps metrics.json 60 s). Polling every
// 60 s therefore shows a new run at most ~90 s after it is published, and a conditional request
// (`If-None-Match`) for an unchanged document returns an empty 304. metrics.json changes slowly
// (daily rollups), so 30 minutes is plenty. docs/forecast.md "Latency" has the end-to-end figures.

import Foundation

public enum ForecastPolling {
    /// Delay between latest.json polls while the app is in the foreground and the last poll
    /// succeeded (a 304 is a success).
    public static let latestInterval: TimeInterval = 60

    /// Delay after 1, 2, and 3 or more consecutive failed polls. Back to `latestInterval` after a
    /// success.
    public static let failureBackoff: [TimeInterval] = [60, 120, 300]

    /// metrics.json is fetched at most this often.
    public static let metricsInterval: TimeInterval = 30 * 60

    /// Delay before the next latest.json poll.
    ///
    /// `consecutiveFailures` is the number of polls that failed (any `ForecastFeedError` except
    /// `.cancelled`, which is not a failure and leaves the count unchanged) since the last success;
    /// 0 after a success. 0 → 60 s, 1 → 60 s, 2 → 120 s, 3 or more → 300 s.
    /// On entering the foreground the app polls immediately, then follows this.
    public static func delayBeforeNextLatestPoll(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures > 0 else { return latestInterval }
        let index = min(consecutiveFailures, failureBackoff.count) - 1
        return failureBackoff[index]
    }

    /// Whether metrics.json should be fetched (alongside a latest.json poll) at `now`.
    ///
    /// `lastSuccessfulFetch` is when metrics.json was last fetched successfully, nil if never.
    /// A failed metrics fetch therefore retries with the next latest.json poll (which backs off on
    /// its own). If the clock moved back past `lastSuccessfulFetch`, the fetch is due.
    public static func isMetricsFetchDue(lastSuccessfulFetch: Date?, now: Date) -> Bool {
        guard let lastSuccessfulFetch else { return true }
        let elapsed = now.timeIntervalSince(lastSuccessfulFetch)
        return elapsed < 0 || elapsed >= metricsInterval
    }
}
