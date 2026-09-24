// DEBUG only: one replay run (PROGRESS D11, D19, D20; docs/replay.md). A ReplayKit scenario source,
// a separate in-memory replay store (never the production database, D20), a pipeline whose gate
// accepts replay readings for the alert engine, and a fresh AlertService configured to accept them.
// The Trio bridge and the uploaders are attached only when the D20 developer switch is on, and then
// refuse every replay reading themselves (S6) and are given no session (the pipeline passes nil to
// the bridge in a replay run, so Trio's App Group is never touched).
//
// `LiveAppServices` runs one of these instead of the sensor pipeline; `ReplayScenarioTests` builds
// the same object with a manual clock and fake ports, so gate 4 exercises this exact wiring.

#if DEBUG
import AlertEngine
import Foundation
import GlucoseCore
import GlucoseStore
import ReplayKit

@MainActor
final class ReplayRun {
    let scenario: ReplayScenario
    let origin: Date
    let source: ReplaySource
    let store: GlucoseStore
    let pipeline: ReadingPipeline
    let alerts: AlertService
    /// The replay's "now" (ahead of the phone clock in an accelerated run).
    let now: @Sendable () -> Date
    private var storeChanges: Task<Void, Never>?

    /// - Parameters:
    ///   - replayClock: plays the timeline (ScaledReplayClock in the app, ManualReplayClock in tests).
    ///   - now: the same time as `replayClock`, synchronously, for the gate, the store and alerts.
    init(scenario: ReplayScenario, origin: Date, replayClock: any ReplayClock, now: @escaping @Sendable () -> Date,
         alertPorts: AlertPorts, settings: AlertSettings, diagnostics: any DiagnosticLog) throws {
        self.scenario = scenario
        self.origin = origin
        self.now = now
        source = scenario.makeSource(origin: origin, clock: replayClock)
        store = try GlucoseStore.replay(diagnostics: diagnostics, now: now)
        pipeline = ReadingPipeline(replayName: "replay:\(scenario.rawValue)", source: source, diagnostics: diagnostics, now: now)
        // No monotonic clock: replay time does not follow it (the engine then checks wall time only).
        alerts = alertPorts.makeReplayService(settings: settings, clock: PipelineAlertClock(now: now, uptime: nil))
        pipeline.outputs.alerts = alerts
        pipeline.attach(store: store)
    }

    /// Starts the alert service, the pipeline and playback.
    func start() async {
        await alerts.start()
        pipeline.startConsuming()
        pipeline.activate()
        let pipeline = self.pipeline
        let changes = store.changes()
        storeChanges = Task {
            for await _ in changes {
                await pipeline.storeDidChange()
            }
        }
        try? await source.start(pairingCode: nil)
    }

    /// Stops playback and discards the run (its streams are not reused).
    func stop() async {
        await source.stop()
        storeChanges?.cancel()
        pipeline.stopConsuming()
    }
}
#endif
