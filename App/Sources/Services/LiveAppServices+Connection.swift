// The sensor connection mode (D45 listen mode), raw packet recording (D47) and the publication
// floor for re-delivered backfill (audit m1) in the live services.
//
// D45: while listening the Trio handoff and both uploaders are off in the services, not only in the
// UI — `TrioCoordinator.activeBridge` is nil (nothing is written to Trio's App Group: no readings, no
// heartbeat keys, no removals) and no uploader exists (nothing is queued). Trio and the Dexcom app
// keep their own paths, so nothing is duplicated. Alerts are unchanged.

import Foundation
import G7Kit
import GlucoseCore

extension LiveAppServices {
    var isListening: Bool { connectionSettings.mode == .listen }

    var connectionMode: SensorConnectionMode { connectionSettings.mode }

    var sharingOffWhileListening: Bool { isListening }

    var recordsRawGlucosePackets: Bool { connectionSettings.recordsRawGlucosePackets }

    func setConnectionMode(_ mode: SensorConnectionMode) async throws(ConnectionModeError) {
        guard !isReplaying else { throw .replayActive }
        guard mode != connectionSettings.mode else { return }
        guard isBootstrapped else {
            throw .credentialStoreFailed("The phone has not been unlocked since it restarted")
        }
        let previous = connectionSettings
        var next = previous
        next.mode = mode
        // Saved first: the next launch must create the source in the mode it is in, because G7Kit
        // deletes a stored pairing of the other mode (SensorConnectionSettings.swift).
        do {
            try connectionSettingsStore.save(next)
        } catch {
            log(.sensor, "connection mode not changed: it could not be saved (\(error))")
            throw .couldNotSave(String(describing: error))
        }
        do {
            try await g7.setMode(next.g7Mode)
        } catch {
            do {
                try connectionSettingsStore.save(previous)
            } catch {
                log(.sensor, "could not restore the saved connection mode after a failed switch: \(error)")
            }
            log(.sensor, "connection mode not changed: \(error)")
            if let startError = error as? G7StartError, case .credentialStoreFailed(let message) = startError {
                throw .credentialStoreFailed(message)
            }
            throw .credentialStoreFailed(String(describing: error))
        }
        connectionSettings = next
        g7Started = false
        supportsCalibration = await g7.supportsCalibration
        log(.sensor, "connection mode: \(next.g7Mode.summary)")

        // The outputs follow at once: off while listening, back on (as the switches say) when pairing.
        configureTrio()
        await applyUploadConfiguration()
        // Listen mode starts with no code; pairing mode waits for `pair(code:)`.
        if mode == .listen { await startG7() }
        await refreshStoredSensor()
        await updateTrioHeartbeat()
        await sendTrioAlertInput()
        for change in [ServiceChange.sensor, .calibration, .trio, .uploads] { send(change) }
    }

    func setRecordsRawGlucosePackets(_ enabled: Bool) async {
        guard enabled != connectionSettings.recordsRawGlucosePackets else { return }
        var next = connectionSettings
        next.recordsRawGlucosePackets = enabled
        do {
            try connectionSettingsStore.save(next)
        } catch {
            // Still applied for this run; the next launch starts with the saved value.
            log(.sensor, "raw glucose packet recording setting could not be saved: \(error)")
        }
        connectionSettings = next
        await g7.setRecordsRawGlucosePackets(enabled)
        log(.sensor, "raw glucose packet recording turned \(enabled ? "on" : "off") (D47)")
        send(.sensor)
    }

    /// Reads what the source says about the mode once it is running (bootstrap).
    func refreshConnectionFromSource() async {
        let mode = await g7.mode
        if mode != connectionSettings.g7Mode {
            log(.sensor, "the G7 source is in \(mode.summary) but the saved mode is \(connectionSettings.g7Mode.summary)")
        }
        let calibrates = await g7.supportsCalibration
        if calibrates != supportsCalibration {
            supportsCalibration = calibrates
            send(.calibration)
        }
    }

    // MARK: - Publication floor for re-delivered backfill (audit m1)

    /// Tells G7Kit the newest reading durably stored for its sensor (nil: none of that sensor's).
    /// Readings that were delivered while the store was failing and lost with the process (held in
    /// memory, then a termination) are published again when the sensor backfills them, with the
    /// same id and date (`isBackfill`); dedupe by id handles the rest. Called when the store opens,
    /// after each successful store write of sensor readings, and when the stored sensor changes.
    func updateG7StoredFloor() async {
        guard let store = productionStore, let serial = await g7.storedSensorSerial else { return }
        do {
            let latest = try await store.latestLiveReading()
            let floor = latest?.sensorSerial == serial ? latest : nil
            await g7.setLatestStoredReading(floor, forSerial: serial)
        } catch {
            log(.store, "latest stored reading not read for G7Kit's backfill floor: \(error)")
        }
    }
}
