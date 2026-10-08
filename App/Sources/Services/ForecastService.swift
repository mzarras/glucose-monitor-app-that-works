// The Zen Predict feed while the app is in the foreground (PROGRESS D57; docs/forecast.md "Polling").
//
// Holds in memory only (D57: a forecast is never stored): the last latest.json and metrics.json that
// ForecastKit validated, when it last tried and succeeded, consecutive failures and the last error
// (`ForecastStatus`). Nothing here reaches the reading pipeline, the store, alerts, Trio, uploads or
// the widget; only the Predict tab and Settings › Predictions read `status`.
//
// When it fetches: only between `enterForeground()` and `enterBackground()`, which LiveAppServices
// calls from `handleForeground()` / `handleBackground()` — never from a Bluetooth wake, a bootstrap
// or a launch by Bluetooth state restoration. On entering the foreground it polls at once, then
// latest.json after `ForecastPolling.delayBeforeNextLatestPoll` (60 s; 60/120/300 s after 1/2/3+
// failures), and metrics.json with a successful latest poll whenever
// `ForecastPolling.isMetricsFetchDue` (30 min). Opening the Predict tab polls at once if the last
// attempt is more than `predictTabRefreshAge` old. A host change or turning predictions off stops
// polling and forgets everything held for the old host.

import ForecastKit
import Foundation

@MainActor
final class ForecastService {
    /// Where the feed comes from. The default (`none`) has no host and refuses every request, so tests
    /// and stand-ins never touch the network; AppEnvironment passes the Info.plist host and URLSession.
    struct Feed {
        /// Info.plist `ZenPredictFeedHost` (= build setting `ZEN_PREDICT_FEED_HOST`); nil or "" = none.
        var buildHost: String?
        var transport: any ForecastTransport
        /// Waits between polls; tests replace it to step through the schedule without waiting.
        var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
        /// Both clocks: the client stamps each document with it (ForecastKit measures a run's age by
        /// the wall and the monotonic clock), and the status times use its wall clock. Tests inject one.
        var clock: @Sendable () -> ForecastInstant = { ForecastInstant.now() }

        static var none: Feed { Feed(buildHost: nil, transport: NoNetworkForecastTransport()) }
    }

    /// Opening the Predict tab fetches at once when the last attempt is older than this.
    static let predictTabRefreshAge: TimeInterval = 30

    private(set) var status: ForecastStatus {
        didSet { if status != oldValue { onChange?() } }
    }
    /// Called on the main actor after every change of `status` (LiveAppServices sends `.forecast`).
    var onChange: (@MainActor () -> Void)?

    private let feed: Feed
    private let log: @MainActor (String) -> Void
    private var client: ForecastFeedClient?
    private var isForeground = false
    private var pollTask: Task<Void, Never>?
    /// Bumped whenever polling stops or the host changes: a request answered after that is dropped.
    private var generation = 0
    /// When metrics.json last succeeded for the current host (ForecastPolling.isMetricsFetchDue).
    private var metricsFetchedAt: Date?
    /// A poll (latest.json, then metrics.json) is running. Opening the tab never restarts one
    /// mid-way: with the client's single-flight requests, cancelling it would cancel the shared
    /// request for every caller.
    private var pollInProgress = false
    /// When the last poll started, by both clocks: the tab's 30-second rule uses the monotonic
    /// clock, so setting the phone's clock does not trigger or suppress a fetch.
    private var lastAttempt: ForecastInstant?
    /// latest.json answers that were `.cancelled` in a row while polling was still wanted (the
    /// system cancelled the request, or this poll joined a request cancelled by a stopped one).
    private var cancelledInARow = 0

    init(feed: Feed, log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.feed = feed
        self.log = log
        let resolved = ForecastSetupRules.resolve(buildHost: feed.buildHost, savedHost: nil, savedEnabled: nil)
        status = ForecastStatus(setup: resolved.setup, buildHost: resolved.buildHost)
        client = resolved.setup.isOn ? Self.makeClient(host: resolved.setup.host, feed: feed) : nil
        if let raw = feed.buildHost, !raw.isEmpty, resolved.buildHost == nil {
            log("forecast feed: the build's host \"\(raw)\" is not a valid host name; ignored")
        }
    }

    // MARK: - Settings

    /// Applies what Settings › Predictions saved (at bootstrap and after every change). A different
    /// host, or turning predictions off, stops polling and forgets everything held.
    func configure(savedHost: String?, savedEnabled: Bool?) {
        let resolved = ForecastSetupRules.resolve(buildHost: feed.buildHost, savedHost: savedHost, savedEnabled: savedEnabled)
        guard resolved.setup != status.setup else { return }
        stopPolling()
        metricsFetchedAt = nil
        status = ForecastStatus(setup: resolved.setup, buildHost: resolved.buildHost)
        client = resolved.setup.isOn ? Self.makeClient(host: resolved.setup.host, feed: feed) : nil
        log("forecast feed: \(Self.describe(resolved.setup))")
        if isForeground { startPolling() }
    }

    private static func makeClient(host: String?, feed: Feed) -> ForecastFeedClient? {
        guard let host, let endpoint = try? ForecastFeedEndpoint(host) else { return nil }
        return ForecastFeedClient(endpoint: endpoint, transport: feed.transport, now: feed.clock)
    }

    private func now() -> Date { feed.clock().wall }

    private static func describe(_ setup: ForecastStatus.Setup) -> String {
        switch setup {
        case .notConfigured: return "not set up"
        case .off(let host): return "off (\(host))"
        case .on(let host): return "on (\(host))"
        }
    }

    // MARK: - Foreground

    /// The app is in the foreground: poll at once (unless already polling), then on schedule.
    func enterForeground() {
        isForeground = true
        startPolling()
    }

    /// The app left the foreground: no more requests. What is held stays (it goes stale on the UI
    /// clock); an answer still on its way is dropped.
    func enterBackground() {
        isForeground = false
        stopPolling()
    }

    /// The Predict tab appeared: poll at once if the last attempt is more than
    /// `predictTabRefreshAge` old (the next poll is then a full interval later).
    func predictTabAppeared() {
        guard isForeground, client != nil, !pollInProgress else { return }
        if let last = lastAttempt, feed.clock().monotonic - last.monotonic <= Self.predictTabRefreshAge { return }
        stopPolling()
        startPolling()
    }

    var isPolling: Bool { pollTask != nil }

    private func startPolling() {
        guard pollTask == nil, isForeground, let client else { return }
        let generation = self.generation
        let sleep = feed.sleep
        pollTask = Task { [weak self] in
            var delay: TimeInterval?
            while !Task.isCancelled {
                if let delay, delay > 0 {
                    do { try await sleep(delay) } catch { return }
                }
                guard let self, self.generation == generation else { return }
                delay = await self.poll(client, generation: generation)
            }
        }
    }

    private func stopPolling() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        pollInProgress = false
        cancelledInARow = 0
        if status.isFetching { status.isFetching = false }
    }

    // MARK: - One poll

    /// latest.json, then metrics.json if due. Returns the delay before the next poll. Results that
    /// arrive after polling stopped or the host changed (`generation`) are dropped, so a cancelled
    /// request never counts as a failure and an old host's document never shows.
    private func poll(_ client: ForecastFeedClient, generation: Int) async -> TimeInterval {
        pollInProgress = true
        defer { if self.generation == generation { pollInProgress = false } }
        let startedAt = feed.clock()
        lastAttempt = startedAt
        var started = status
        started.isFetching = true
        started.lastAttemptAt = startedAt.wall
        status = started
        let result: Result<LatestForecast, ForecastFeedError>
        do {
            result = .success(try await client.fetchLatest())
        } catch {
            result = .failure(error)
        }
        // Stopped meanwhile (background, new host, tab-appear restart): the answer, or the
        // cancellation it ended in, is neither shown nor counted as a failure.
        guard self.generation == generation, !Task.isCancelled else { return ForecastPolling.latestInterval }
        var next = status
        next.isFetching = false
        if case .failure(.cancelled) = result {
            // Polling is still wanted, so the request was cancelled under us (the system, or a
            // request shared with a poll that was stopped). Not a failure: no backoff, no error
            // shown. Ask again at once the first time, then on the usual schedule.
            status = next
            cancelledInARow += 1
            return cancelledInARow == 1 ? 0 : ForecastPolling.delayBeforeNextLatestPoll(consecutiveFailures: status.consecutiveFailures)
        }
        cancelledInARow = 0
        switch result {
        case .success(let latest):
            next.latest = latest
            next.lastSuccessAt = now()
            next.consecutiveFailures = 0
            next.lastError = nil
        case .failure(let error):
            next.consecutiveFailures += 1
            next.lastError = error.description
            if next.consecutiveFailures == 1 { log("forecast feed: \(error.description)") }
        }
        status = next
        if case .success = result, ForecastPolling.isMetricsFetchDue(lastSuccessfulFetch: metricsFetchedAt, now: now()) {
            await fetchAccuracy(client, generation: generation)
        }
        return ForecastPolling.delayBeforeNextLatestPoll(consecutiveFailures: status.consecutiveFailures)
    }

    /// A failure keeps the last accuracy and is retried with the next successful latest poll.
    private func fetchAccuracy(_ client: ForecastFeedClient, generation: Int) async {
        do {
            let accuracy = try await client.fetchAccuracy()
            guard self.generation == generation else { return }
            status.accuracy = accuracy
            metricsFetchedAt = now()
        } catch {
            guard self.generation == generation, error != .cancelled else { return }
            log("forecast feed: metrics.json: \(error.description)")
        }
    }
}

/// The default transport: refuses every request. No feed is reachable without a real one.
struct NoNetworkForecastTransport: ForecastTransport {
    func send(_ request: URLRequest) async throws(ForecastTransportError) -> ForecastHTTPResponse {
        throw ForecastTransportError(message: "No forecast transport in this build.")
    }
}
