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

    /// Switches the mode, or — while `connectionSettingProblem` is set — records the person's choice
    /// again (even the mode the source happens to be in) and starts the source in it.
    func setConnectionMode(_ mode: SensorConnectionMode) async throws(ConnectionModeError) {
        guard !isReplaying else { throw .replayActive }
        let resolving = connectionSettingProblem != nil
        guard resolving || mode != connectionSettings.mode else { return }
        guard isBootstrapped else {
            throw .credentialStoreFailed("The phone has not been unlocked since it restarted")
        }
        let previous = connectionSettings
        var next = previous
        next.mode = mode
        // Saved first: the next launch must create the source in the mode it is in, because G7Kit
        // deletes a stored pairing of the other mode (SensorConnectionSettings.swift). While
        // resolving, this rewrites the unreadable or wrong file (review m2).
        do {
            try connectionSettingsStore.save(next)
        } catch {
            log(.sensor, "connection mode not changed: it could not be saved (\(error))")
            throw .couldNotSave(String(describing: error))
        }
        let sourceMode = await g7.mode
        do {
            if sourceMode != next.g7Mode {
                try await allowingDeletion { try await g7.setMode(next.g7Mode) }
            }
        } catch {
            log(.sensor, "connection mode not changed: \(error)")
            // G7Kit stopped the source and kept its mode. Put the saved mode back so the next launch
            // creates the source in that mode (review m3), then resume it.
            if !resolving {
                if let failure = restoreSavedSettings(previous) {
                    connectionSettingProblem = "The connection mode could not be changed and the previous setting could not be saved back (\(failure))"
                    log(.sensor, "connection setting problem: \(connectionSettingProblem ?? "")")
                } else {
                    g7Started = false
                    await startG7()
                }
            }
            for change in [ServiceChange.sensor, .health] { send(change) }
            if let startError = error as? G7StartError, case .credentialStoreFailed(let message) = startError {
                throw .credentialStoreFailed(message)
            }
            throw .credentialStoreFailed(String(describing: error))
        }
        // Review m1: leaving pairing mode for listen mode removes this app's readings and heartbeat
        // keys from Trio's App Group — the handoff is turned off first, so nothing is written after.
        let trioWasActive = trioCoordinator.activeBridge != nil
        connectionSettings = next
        if resolving {
            log(.sensor, "connection setting chosen again: \(next.g7Mode.summary)")
            connectionSettingProblem = nil
            credentialGuard?.clearRefusal()
        }
        g7Started = false
        supportsCalibration = await g7.supportsCalibration
        log(.sensor, "connection mode: \(next.g7Mode.summary)")

        // The outputs follow at once: off while listening, back on (as the switches say) when pairing.
        configureTrio()
        if mode == .listen, trioWasActive {
            await trioCoordinator.removeEverythingFromTrio(enteringListenMode: true)
        }
        await applyUploadConfiguration()
        // Listen mode starts with no code; pairing mode waits for `pair(code:)` — except when the
        // person chose again after a problem: the source was never started, and a stored pairing of
        // this mode resumes (one of the other mode is dropped: the person's choice).
        if mode == .listen || resolving {
            await allowingDeletion { await startG7() }
        }
        await refreshStoredSensor()
        await updateTrioHeartbeat()
        await sendTrioAlertInput()
        for change in [ServiceChange.sensor, .calibration, .trio, .uploads, .health] { send(change) }
    }

    /// Review m3: writes `settings` back, retrying; returns the last error if it never succeeded.
    private func restoreSavedSettings(_ settings: SensorConnectionSettings) -> String? {
        var failure: String?
        for attempt in 1...Self.restoreAttempts {
            do {
                try connectionSettingsStore.save(settings)
                if attempt > 1 { log(.sensor, "previous connection setting saved back on attempt \(attempt)") }
                return nil
            } catch {
                failure = String(describing: error)
                log(.sensor, "could not save the previous connection setting back (attempt \(attempt)): \(error)")
            }
        }
        return failure
    }

    static let restoreAttempts = 3

    /// The person's own action: G7Kit may delete the pairing record meanwhile.
    func allowingDeletion<T>(_ body: @MainActor () async throws -> T) async rethrows -> T {
        if let credentialGuard { return try await credentialGuard.allowingDeletion(body) }
        return try await body()
    }

    /// G7Kit was kept from deleting a pairing record (GuardedG7CredentialStore): the mode the source
    /// was created in does not match the stored pairing. Nothing is deleted or started until the
    /// person chooses again.
    func noteRefusedDeletion() {
        guard let refusal = credentialGuard?.refusedDeletion, connectionSettingProblem == nil else { return }
        connectionSettingProblem = "The saved connection setting does not match the stored sensor connection (\(refusal))"
        log(.sensor, "connection setting problem: \(connectionSettingProblem ?? "")")
        send(.sensor)
        send(.health)
    }

    func setRecordsRawGlucosePackets(_ enabled: Bool) async {
        guard enabled != connectionSettings.recordsRawGlucosePackets else { return }
        var next = connectionSettings
        next.recordsRawGlucosePackets = enabled
        do {
            // While the connection setting is unresolved, writing the file would record a mode the
            // person did not choose: applied for this run only.
            guard connectionSettingProblem == nil else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "the connection setting is not resolved"])
            }
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
