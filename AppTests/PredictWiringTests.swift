// PROGRESS D57 end to end: the model re-evaluates the forecast on its clock tick (no fetch needed to
// go "out of date"), Settings › Predictions reaches the facade, and the live services fetch only in
// the foreground and never let a forecast reach the store, the widget, Trio or the alert engine.

import AlertEngine
import ForecastKit
import Foundation
import GlucoseCore
import NightscoutKit
import XCTest
@testable import Sensor

@MainActor
final class PredictWiringTests: XCTestCase {
    private let clock = TestClock(t0)

    private func launch(_ services: PreviewAppServices) -> AppModel {
        let preferences = AppUIPreferences(defaults: UserDefaults(suiteName: "PredictWiringTests.\(UUID().uuidString)")!)
        preferences.onboardingCompleted = true
        let clock = self.clock
        let model = AppModel.launch(services: services, arguments: ["-tab", "predict"], preferences: preferences, calendar: utcCalendar,
                                    clock: { clock.now }, protectedDataAvailable: { true })
        model.apply(.sensor)
        return model
    }

    /// Readings every 5 min for 3 h up to the run's time, and a current run 3 min old.
    private func servicesWithACurrentRun() -> PreviewAppServices {
        let readings = series(from: minutes(-183), to: minutes(-2.99)) { _ in .mgdl(105) }
        let services = PreviewAppServices(readings: readings, sensorState: activeSensor)
        services.latestLiveReading = readings.last
        services.forecast = ForecastTestDocuments.status(latest: ForecastTestDocuments.decodedLatest(run: minutes(-3), now: t0),
                                                         accuracy: ForecastTestDocuments.accuracy(now: t0))
        return services
    }

    // MARK: - The model

    func test_S1_predictHidesAStaleForecastWithoutAFetch() async throws {
        let services = servicesWithACurrentRun()
        let model = launch(services)
        await model.settle()
        let shown = try XCTUnwrap(model.predict.forecast, "\(model.predict.content)")
        XCTAssertEqual(shown.columns.map(\.value), ["98", "105", "121"])
        XCTAssertFalse(try XCTUnwrap(model.predict.chart).forecast.isEmpty)

        // 15 minutes after the run: still current.
        clock.now = minutes(12)
        model.tick()
        XCTAssertNotNil(model.predict.forecast)

        // One second later, with nothing fetched or sent: the next UI tick hides it.
        let statusBefore = services.forecast
        clock.now = minutes(12).addingTimeInterval(1)
        model.tick()
        XCTAssertEqual(services.forecast, statusBefore, "no fetch happened")
        XCTAssertNil(model.predict.forecast)
        XCTAssertTrue(try XCTUnwrap(model.predict.chart).forecast.isEmpty, "no forecast line")
        guard case .outOfDate(let message) = model.predict.content else { return XCTFail("\(model.predict.content)") }
        XCTAssertTrue(message.detail.hasPrefix("Last model run 15 min ago"), message.detail)
    }

    /// D59: the phone's clock is set back 10 minutes while the tab is open. The model's tick asks
    /// ForecastKit at an instant with both clocks, so the run still goes out of date 15 minutes after
    /// it was made, by the monotonic clock, with no fetch.
    func test_S1_aClockSetBackDoesNotKeepAForecastCurrent() async throws {
        let services = servicesWithACurrentRun() // decoded at t0 (fixture clock: monotonic = t0's seconds)
        let clocks = ClockPair(wall: t0, monotonic: t0.timeIntervalSince1970)
        let preferences = AppUIPreferences(defaults: UserDefaults(suiteName: "PredictWiringTests.\(UUID().uuidString)")!)
        preferences.onboardingCompleted = true
        let model = AppModel.launch(services: services, arguments: ["-tab", "predict"], preferences: preferences, calendar: utcCalendar,
                                    clock: { clocks.wall }, forecastClock: PredictClock { ForecastInstant(wall: clocks.wall, monotonic: clocks.monotonic) },
                                    protectedDataAvailable: { true })
        model.apply(.sensor)
        await model.settle()
        XCTAssertNotNil(model.predict.forecast)

        // 12 min of real time later the clock reads 10 min less: by the wall the run is 5 min old.
        clocks.monotonic += 12 * 60 + 1
        clocks.wall = t0.addingTimeInterval(2 * 60 + 1)
        let statusBefore = services.forecast
        model.tick()
        XCTAssertEqual(services.forecast, statusBefore, "no fetch")
        XCTAssertNil(model.predict.forecast, "out of date by the monotonic clock")
        guard case .outOfDate = model.predict.content else { return XCTFail("\(model.predict.content)") }
    }

    /// Both clocks a test moves by hand.
    @MainActor
    private final class ClockPair {
        var wall: Date
        var monotonic: TimeInterval
        init(wall: Date, monotonic: TimeInterval) {
            self.wall = wall
            self.monotonic = monotonic
        }
    }

    func test_D57_aForecastChangeRebuildsPredictAndSettings() async {
        let services = PreviewAppServices(sensorState: activeSensor)
        let model = launch(services)
        XCTAssertEqual(model.predict, .notConfigured)
        XCTAssertEqual(model.settings.predictions.rowValue, "not set up")

        services.forecast = ForecastTestDocuments.status(latest: ForecastTestDocuments.decodedLatest(run: minutes(-3), now: t0))
        services.send(.forecast)
        let shown = await eventually { model.predict.forecast != nil }
        XCTAssertTrue(shown, "\(model.predict.content)")
        XCTAssertEqual(model.settings.predictions.rowValue, "on · zen.example.com")
    }

    func test_D57_settingsPredictionsActionsReachTheFacade() async {
        let services = PreviewAppServices(sensorState: activeSensor)
        services.forecast = ForecastStatus(setup: .on(host: "zen.example.com"), buildHost: "zen.example.com")
        let model = launch(services)

        model.savePredictionsHost("http://zen.example.org")
        await model.settle()
        XCTAssertEqual(model.settings.feedback.predictions, "Only https:// is supported.", "ForecastFeedEndpoint's sentence, shown under the field")
        XCTAssertEqual(services.forecast.setup, .on(host: "zen.example.com"), "nothing changed")

        model.savePredictionsHost(" https://Zen.Example.org/ ")
        await model.settle()
        XCTAssertEqual(model.settings.feedback.predictions, "Saved.")
        let updated = await eventually { model.settings.predictions.setup == .on(host: "zen.example.org") }
        XCTAssertTrue(updated)

        model.setPredictionsEnabled(false)
        await model.settle()
        let off = await eventually { model.predict.content == .turnedOff(host: "zen.example.org") }
        XCTAssertTrue(off)
        XCTAssertEqual(services.calls.filter { $0.hasPrefix("save") || $0.hasPrefix("setPredictions") },
                       ["savePredictionsHost(http://zen.example.org)", "savePredictionsHost( https://Zen.Example.org/ )", "setPredictionsEnabled(false)"])
    }

    func test_D57_predictTabAppearanceAndSetUpButton() {
        let services = PreviewAppServices(sensorState: activeSensor)
        let model = launch(services)
        model.predictTabAppeared()
        XCTAssertEqual(services.calls.filter { $0 == "predictTabAppeared" }.count, 1)
        model.openPredictionsSettings()
        XCTAssertEqual(model.selectedTab, .settings)
        XCTAssertEqual(model.settingsRoute, .predictions)
    }

    // MARK: - The live services

    private func liveHarness(restoration: Bool = false, zen: [Int: Double] = ForecastFixtureDocuments.zen,
                             persistence: LiveServicesHarness.Persistence,
                             uploadTransport: (any HTTPTransport)? = nil) async -> (LiveServicesHarness, FakeForecastTransport, ManualSleeper) {
        let clock = persistence.clock
        let sleeper = ManualSleeper()
        let transport = FakeForecastTransport(latest: FakeForecastTransport.ok(ForecastTestDocuments.latest(run: clock.now.addingTimeInterval(-180), zen: zen)),
                                              metrics: FakeForecastTransport.ok(ForecastFixtureDocuments.metrics(asOf: clock.now.addingTimeInterval(-600))))
        let feed = ForecastService.Feed(buildHost: ForecastTestDocuments.host, transport: transport,
                                        sleep: { try await sleeper.sleep($0) }, clock: { ForecastFixtureDocuments.instant(clock.now) })
        let harness = LiveServicesHarness(persistence, launchedByBluetoothRestoration: restoration, uploadTransport: uploadTransport, forecastFeed: feed)
        return (harness, transport, sleeper)
    }

    func test_D57_liveServicesFetchOnlyBetweenForegroundAndBackground() async {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let (harness, transport, sleeper) = await liveHarness(persistence: persistence)
        let services = harness.services
        await services.bootstrap()
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(120), at: persistence.clock.now.addingTimeInterval(-10)))
        await harness.wake()
        var count = await transport.count
        XCTAssertEqual(count, 0, "no fetch at bootstrap, on a reading or on a wake")
        XCTAssertEqual(services.forecast.setup, .on(host: ForecastTestDocuments.host))

        let stream = services.changes()
        await services.handleForeground()
        await waitUntil("forecast fetched") { services.forecast.latest != nil && sleeper.sleeping == 1 }
        let paths = await transport.paths
        XCTAssertEqual(paths, ["latest.json", "metrics.json"])
        services.send(.appearance) // end marker
        var changes: [ServiceChange] = []
        for await change in stream {
            if change == .appearance { break }
            changes.append(change)
        }
        XCTAssertTrue(changes.contains(.forecast), "the facade announces the forecast")

        services.handleBackground()
        XCTAssertFalse(services.forecastService.isPolling)
        await waitUntil("the sleeping poll ends") { sleeper.sleeping == 0 }
        await harness.wake()
        count = await transport.count
        XCTAssertEqual(count, 2, "nothing in the background")
    }

    /// The scene's path (AppEnvironment → `sceneBecameActive()`) starts the forecast like
    /// `handleForeground()`; a `.background` that arrives before that work runs wins, so nothing is
    /// fetched in the background.
    func test_D57_sceneBecameActiveFetchesAndAnImmediateBackgroundWins() async {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let (harness, transport, sleeper) = await liveHarness(persistence: persistence)
        let services = harness.services
        await services.bootstrap()

        let quick = services.sceneBecameActive()
        services.handleBackground()
        await quick.value
        var count = await transport.count
        XCTAssertEqual(count, 0, "background arrived first: no fetch")
        XCTAssertFalse(services.forecastService.isPolling)

        await services.sceneBecameActive().value
        await waitUntil("forecast fetched") { services.forecast.latest != nil && sleeper.sleeping == 1 }
        count = await transport.count
        XCTAssertEqual(count, 2, "latest and metrics")
        services.handleBackground()
        XCTAssertFalse(services.forecastService.isPolling)
    }

    func test_D57_noFetchDuringALaunchByBluetoothRestoration() async {
        let persistence = LiveServicesHarness.Persistence(now: Date())
        let (harness, transport, _) = await liveHarness(restoration: true, persistence: persistence)
        await harness.services.bootstrap()
        harness.services.protectedDataDidBecomeAvailable()
        await harness.deliver(state: harness.activeState)
        await harness.deliver(persistence.reading(.mgdl(120), at: persistence.clock.now.addingTimeInterval(-10)))
        await harness.wake()
        for _ in 0..<50 { await Task.yield() }
        let count = await transport.count
        XCTAssertEqual(count, 0, "a Bluetooth wake or restoration bootstrap never fetches the forecast")
        XCTAssertFalse(harness.services.forecastService.isPolling)
    }

    /// The forecast predicts an urgent low (45 → 40). Fetching it changes nothing that handles
    /// readings: the store, the widget's snapshot, Trio's App Group, the alert engine's state and the
    /// notifications are exactly as before, and nothing fires.
    func test_S1_forecastNeverReachesStoreWidgetTrioOrAlerts() async throws {
        let now = Date()
        let persistence = LiveServicesHarness.Persistence(now: now)
        // Nightscout and Dexcom Share on, into a recording transport (m3: uploads too).
        let preferences = persistence.preferences
        preferences.nightscoutUploadEnabled = true
        preferences.nightscoutSiteURL = "https://ns.example.invalid"
        preferences.dexcomShareUploadEnabled = true
        preferences.dexcomShareReceiverSerial = "SM12345678"
        let uploads = RecordingTransport()
        let (harness, transport, sleeper) = await liveHarness(zen: [5: 45, 30: 42, 60: 40, 120: 40], persistence: persistence, uploadTransport: uploads)
        try harness.credentials.write("token", for: .nightscoutToken)
        try harness.credentials.write("account", for: .dexcomShareAccountName)
        try harness.credentials.write("password", for: .dexcomSharePassword)
        let services = harness.services
        await services.bootstrap()
        XCTAssertEqual(services.uploads.activeUploaders.count, 2, "both uploaders run")
        await harness.deliver(state: harness.activeState)
        await transport.holdNextRequest()
        await services.handleForeground()
        await waitUntil("forecast request on its way") { await transport.isHolding }
        let reading = persistence.reading(.mgdl(120), at: now.addingTimeInterval(-10))
        await harness.deliver(reading)
        await waitUntil("idle") { services.sensorPipeline.isIdle }

        await services.retryUploads()
        await waitUntil("the reading went to Nightscout") { uploads.requests.contains { $0.url?.host() == "ns.example.invalid" } }
        let sent = await settledUploadCount(uploads)
        let queues = uploadQueues(persistence)

        let stored = try await services.readings(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(3_600))
        let widget = harness.widget.published
        let trio = persistence.trioStore.payload as NSArray
        let alertState = persistence.preferences.alertEngineSnapshot
        let posted = persistence.center.posted.count
        XCTAssertEqual(stored.map(\.id), [reading.id])

        await transport.release()
        await waitUntil("forecast held") { services.forecast.latest != nil && sleeper.sleeping == 1 }
        let held = try XCTUnwrap(services.forecast.latest)
        XCTAssertNotNil(PredictFreshness.currentRun(held, at: ForecastFixtureDocuments.instant(persistence.clock.now)), "a current forecast of 45 → 40 is held")
        await waitUntil("idle") { services.sensorPipeline.isIdle }

        let storedAfter = try await services.readings(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(3_600))
        XCTAssertEqual(storedAfter, stored, "no forecast is stored")
        XCTAssertEqual(harness.widget.published, widget, "the widget was not republished for a forecast")
        XCTAssertTrue((persistence.trioStore.payload as NSArray).isEqual(trio), "Trio's App Group is untouched")
        XCTAssertEqual(persistence.preferences.alertEngineSnapshot, alertState, "the alert engine saw no new input")
        XCTAssertEqual(persistence.center.posted.count, posted, "no notification")
        XCTAssertEqual(services.latestLiveReading, reading, "the current value is still the reading")
        let sentAfter = await settledUploadCount(uploads)
        XCTAssertEqual(sentAfter, sent, "nothing uploaded for a forecast")
        XCTAssertEqual(uploadQueues(persistence), queues, "nothing queued for upload")

        // A wake after the forecast arrived: still only the reading everywhere.
        await harness.wake()
        let sentAtEnd = await settledUploadCount(uploads)
        XCTAssertEqual(sentAtEnd, sent)
        XCTAssertEqual(uploadQueues(persistence), queues)
        XCTAssertEqual(harness.widget.published.last, reading.id)
        XCTAssertFalse(harness.isFiring(.urgentLow))
        XCTAssertFalse(harness.isFiring(.low))
        XCTAssertFalse(harness.isFiring(.urgentLowSoon))
        let storedAtEnd = try await services.readings(from: now.addingTimeInterval(-86_400), to: now.addingTimeInterval(3_600))
        XCTAssertEqual(storedAtEnd, stored)
        services.handleBackground()
    }

    /// The upload request count once it has stopped changing (flushes run in their own tasks).
    private func settledUploadCount(_ uploads: RecordingTransport) async -> Int {
        var last = -1
        var stableFor = 0
        while stableFor < 5 {
            try? await Task.sleep(for: .milliseconds(50))
            let count = uploads.requests.count
            stableFor = count == last ? stableFor + 1 : 0
            last = count
        }
        return last
    }

    /// Every upload queue file and its contents (Application Support/Uploads in the harness).
    private func uploadQueues(_ persistence: LiveServicesHarness.Persistence) -> [String: Data] {
        let directory = persistence.directory.appendingPathComponent("Uploads")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Dictionary(uniqueKeysWithValues: names.map { ($0, (try? Data(contentsOf: directory.appendingPathComponent($0))) ?? Data()) })
    }
}
