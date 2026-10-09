// DEBUG only: replay runs in the live app (PROGRESS D11, D19, D20; docs/replay.md; HANDOFF §11
// step 1). A run replaces the sensor pipeline for its duration:
// - the G7 source is stopped and its pipeline holds any event (nothing from it is lost);
// - the production alert service is released (one AlertService at a time) and a replay service
//   that accepts replay readings takes over; when the run ends the production service is rebuilt
//   from its persisted snapshot and reconciles what the run left pending (`.launched`); the
//   media-volume monitor (D55) moves with the active service;
// - readings go to a separate in-memory replay store, never the production database (D20);
// - the Trio bridge and uploaders are attached only when the developer switch is on, and refuse
//   every replay reading themselves (S6).
// Launch arguments (UI tests, demos): `-replayScenario <name>` [`-replaySpeed <x>`] [`-replayStartMinute <m>`].

#if DEBUG
import AlertEngine
import Foundation
import GlucoseCore
import ReplayKit

enum ReplayScenarioNames {
    static var all: [String] { ReplayScenario.allCases.map(\.rawValue) }
}

extension LiveAppServices {
    var replayClockNow: Date? { replayRun?.now() }

    func startReplay(scenario: String, speed: Double) async {
        await startReplay(scenario: scenario, speed: speed, startingAtMinute: 0)
    }

    /// - Parameters:
    ///   - speed: scenario seconds per real second (1 = real time; faster runs ahead of the phone clock).
    ///   - startingAtMinute: begin this far into the scenario; everything before it is delivered at once.
    func startReplay(scenario name: String, speed: Double, startingAtMinute: Double) async {
        guard isBootstrapped, let scenario = ReplayScenario(rawValue: name) else {
            log(.app, "replay not started: unknown scenario \"\(name)\" or not bootstrapped")
            return
        }
        await stopReplay()
        let speed = speed.isFinite && speed > 0 ? speed : 1
        let offset = max(0, startingAtMinute.isFinite ? startingAtMinute : 0) * 60

        // Hold the sensor: its pipeline keeps every event until the run ends.
        sensorPipeline.deactivate()
        await g7.stop()
        g7Started = false
        // D55: the audio player has one volume monitor; the replay service takes it over below.
        productionAlerts?.setVolumeMonitoring(false)
        productionAlerts = nil
        sensorPipeline.outputs.alerts = nil

        let wallStart = Date()
        let clock = ScaledReplayClock(start: wallStart, speed: speed)
        do {
            let run = try ReplayRun(
                scenario: scenario, origin: wallStart.addingTimeInterval(-offset), replayClock: clock, now: { clock.now() },
                alertPorts: alertPorts, settings: alertSettings, diagnostics: diagnostics
            )
            run.pipeline.outputs.widget = widget
            run.pipeline.onChange = { [weak self] change in self?.send(change) }
            run.pipeline.onBatchProcessed = { [weak self] in self?.updateClockMismatchLatch(now: Date()) }
            replayRun = run
            replaySpeed = speed
            replayClockMismatch = .initial
            updateVolumeMonitoring() // D55: the replay service is the active one now
            attachOutputs()
            await run.start()
            await sendTrioAlertInput(force: true)
            log(.app, "replay started: \(name) at \(speed)×, from minute \(Int(offset / 60))")
        } catch {
            log(.app, "replay could not start: \(error)")
            await resumeSensor()
        }
        for change in [ServiceChange.replay, .readings, .sensor, .alertSettings, .health] { send(change) }
    }

    func stopReplay() async {
        guard let run = replayRun else { return }
        await run.stop()
        // D55: production takes the audio player's volume monitor over in `resumeSensor`.
        run.alerts.setVolumeMonitoring(false)
        replayRun = nil
        replaySpeed = nil
        log(.app, "replay stopped: \(run.scenario.rawValue)")
        await resumeSensor()
        for change in [ServiceChange.replay, .readings, .sensor, .health] { send(change) }
    }

    /// Back to the sensor: a production alert service from the persisted snapshot, the sensor
    /// pipeline active again (held events flow), the G7 source started.
    private func resumeSensor() async {
        let alerts = makeProductionAlerts()
        productionAlerts = alerts
        sensorPipeline.outputs.alerts = alerts
        updateVolumeMonitoring() // D55
        await alerts.start()
        // The app is in the foreground when a replay run is stopped: production's expiry reminders
        // are written again (D43; the replay service had `.foreground` while the run lasted).
        await alerts.send(.foreground)
        await sendTrioAlertInput(force: true)
        attachOutputs()
        sensorPipeline.activate()
        await startG7()
        await updateTrioHeartbeat()
    }

    func setDeveloperLiveOutputsEnabled(_ enabled: Bool) async {
        preferences.developerLiveOutputs = enabled
        log(.app, "developer switch for live outputs (D20) turned \(enabled ? "on" : "off")")
        configureTrio()
        await applyUploadConfiguration()
        if enabled {
            await reseedTrio()
            await updateTrioHeartbeat()
        }
        await sendTrioAlertInput()
        send(.replay)
    }
}
#endif
