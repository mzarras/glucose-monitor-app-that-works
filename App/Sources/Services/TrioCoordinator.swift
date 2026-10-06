// Owns the app's one TrioBridge (docs/trio-bridge.md "One instance per process"): the user's
// switch, the D20 DEBUG switch, the status shown in Settings and fed to the alert engine, the
// heartbeat keys (docs/trio-bridge.md "Heartbeat wiring"), retries, and the launch re-seed.
//
// Imports TrioBridge and G7Kit but not AlertEngine (both TrioBridge and AlertEngine declare a
// `TrioBridgeStatus`; `TrioBridgeStatus` here is TrioBridge's).

import Foundation
import G7Kit
import GlucoseCore
import TrioBridge

@MainActor
final class TrioCoordinator {
    /// Nil when this build has no usable `TrioAppGroupID` in Info.plist (nothing can reach Trio;
    /// Settings shows it and the bridge can't be enabled).
    let bridge: TrioBridge?
    private(set) var summary: TrioBridgeSummary
    /// Called after every change of `summary`.
    var onChange: (@MainActor (TrioBridgeSummary) -> Void)?

    private let diagnostics: any DiagnosticLog
    /// Trio's App Group suite, read once for the newest reading a previous process left there.
    private let sharedStore: (any TrioSharedStore)?
    private var statusTask: Task<Void, Never>?
    /// Review m1 (Phase 3 carry-over): until the launch re-seed, or a write that carries a reading
    /// newer than what the App Group already holds, readings not newer than the App Group's newest
    /// are held here and never written on their own — so no write of this process makes Trio's
    /// newest reading go backwards. They go out with the next newer reading or with the re-seed.
    /// A long hold stays visible (`heldBackReadings`, starving after 15 min).
    private var holdsOlderReadings = true
    private var heldOlderReadings: [GlucoseReading] = []
    private var appGroupNewestAtLaunch: Date??
    private var holdStartedAt: Date?
    private let clock: @Sendable () -> Date
    /// What this process last wrote as the heartbeat (nil = removed), and whether that write
    /// succeeded; a failed or unknown state is rewritten at the next re-evaluation.
    private var heartbeatWritten: TrioHeartbeatPeripheral?
    private var heartbeatInSync = false

    /// - Parameters:
    ///   - appGroupID: Info.plist `TrioAppGroupID`.
    ///   - store: Trio's App Group suite (`AppGroupUserDefaultsStore`); tests pass a fake.
    init(appGroupID: String?, store: (any TrioSharedStore)?, diagnostics: any DiagnosticLog, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.diagnostics = diagnostics
        // PROGRESS D21 (Michael): LOW → 39 and HIGH → 401 in Trio's payload; the package default withholds both.
        let policy = OutOfRangePolicy(low: .writeSentinel, high: .writeSentinel) // D21: LOW → 39, HIGH → 401, never 40/400 (S4)
        self.bridge = store.map { TrioBridge(store: $0, outOfRangePolicy: policy, diagnostics: diagnostics, clock: clock) }
        self.sharedStore = store
        self.clock = clock
        var summary = TrioBridgeSummary.off
        summary.appGroupID = appGroupID
        self.summary = summary
    }

    /// Starts observing the bridge's status. Call once.
    func start() {
        guard statusTask == nil, let bridge else { return }
        statusTask = Task { [weak self] in
            for await status in await bridge.statusUpdates() {
                guard let self else { return }
                self.summary.update(from: status, now: self.clock())
                self.onChange?(self.summary)
            }
        }
    }

    /// The user's switch, the D20 DEBUG switch (always true in Release) and D45 listen mode, which
    /// turns the handoff off whatever the switch says: nothing is written to Trio's App Group while
    /// listening (readings, heartbeat keys, removals), Trio keeps its own CGM path.
    func configure(enabled: Bool, liveOutputsAllowed: Bool, listening: Bool = false) {
        summary.isEnabled = enabled
        summary.liveOutputsAllowed = liveOutputsAllowed
        if listening != summary.offWhileListening {
            log(listening ? "off while the sensor is in listen mode (D45)" : "listen mode ended")
        }
        summary.offWhileListening = listening
        summary.refreshStarvation(now: clock())
        if enabled, liveOutputsAllowed, !listening, bridge == nil {
            // Turned on, but this build cannot reach Trio at all: fail loud (S5, review minor 4).
            summary.unavailableReason = "This build has no Trio App Group (Info.plist TrioAppGroupID is missing), so nothing reaches Trio. Rebuild with the team ID set (docs/trio-bridge.md, Setup)."
            summary.problemSince = summary.problemSince ?? clock()
            log("turned on but unavailable: no TrioAppGroupID in this build")
        } else {
            summary.unavailableReason = nil
            if !summary.isFailing, !summary.isStarving { summary.problemSince = nil }
        }
        onChange?(summary)
    }

    /// The bridge the pipeline should write to: nil while off, not allowed, listening (D45), or
    /// unavailable.
    var activeBridge: TrioBridge? {
        summary.isEnabled && summary.liveOutputsAllowed && !summary.offWhileListening ? bridge : nil
    }

    /// The pipeline's path to Trio: gate-passed readings (the bridge gates them again). Returns nil
    /// when nothing was handed to the bridge (off, not allowed, or held — see `holdsOlderReadings`).
    @discardableResult
    func publish(_ readings: [GlucoseReading], session: SensorSession?) async -> TrioPublishResult? {
        guard let bridge = activeBridge else { return nil }
        var toWrite = readings
        if holdsOlderReadings, !readings.isEmpty, let floor = appGroupNewestBeforeThisProcess() {
            let older = readings.filter { $0.date <= floor }
            let newer = readings.filter { $0.date > floor }
            if newer.isEmpty {
                // After a relaunch G7Kit may deliver backfill the App Group already has. Written alone
                // it would replace the previous payload with older readings: it waits instead, however
                // long (a slow or failed store open included), for a newer reading or the re-seed.
                heldOlderReadings += older
                if holdStartedAt == nil { holdStartedAt = clock() }
                noteHold()
                log("holding \(older.count) reading(s) not newer than Trio's current newest (\(floor.ISO8601Format())) until a newer reading or the launch re-seed")
                return nil
            }
            // A newer reading keeps Trio's newest moving forward; the held ones go with it.
            toWrite = newer + older + takeHeldReadings()
        } else if holdsOlderReadings, !readings.isEmpty {
            // No usable floor (an empty, unreadable or future App Group newest): nothing to protect.
            toWrite = readings + takeHeldReadings()
        }
        return await bridge.publish(toWrite, session: session)
    }

    /// Ends the launch hold and returns what it held.
    private func takeHeldReadings() -> [GlucoseReading] {
        let held = heldOlderReadings
        heldOlderReadings = []
        holdsOlderReadings = false
        holdStartedAt = nil
        noteHold()
        return held
    }

    /// Shows held readings in the summary, so a hold is never invisible (review m5): they count as
    /// starving Trio once held for the starvation threshold, like readings the bridge refused.
    private func noteHold() {
        summary.heldBackReadings = heldOlderReadings.count
        summary.heldBackSince = heldOlderReadings.isEmpty ? nil : holdStartedAt
        summary.refreshStarvation(now: clock())
        onChange?(summary)
    }

    /// Hands recent stored readings to the bridge (launch re-seed and switching it on), with any
    /// readings held until now. Every one passes the gate again inside the bridge; only `.sensor`
    /// readings are offered (S6).
    func reseed(with readings: [GlucoseReading], session: SensorSession?) async {
        guard let bridge = activeBridge else { return }
        let live = (readings + takeHeldReadings()).filter { $0.source.isLiveSensor }
        let result = await bridge.publish(live, session: session)
        log("re-seeded with \(live.count) stored or held sensor reading(s): \(result.addedReadingIDs.count) written, \(result.refusals.count) refused")
    }

    /// The newest reading time in Trio's App Group as this process found it (read once; nil if
    /// none, unreadable, or not in the expected `"/Date(<ms>)/"` form).
    private func appGroupNewestBeforeThisProcess() -> Date? {
        if let known = appGroupNewestAtLaunch { return known }
        var newest = Self.newestReadingDate(in: sharedStore?.data(forKey: TrioAppGroupContract.readingsKey))
        // A floor in the future (another app's clock fault, a phone clock set back) would hold every
        // valid reading: it is ignored (review m5).
        if let found = newest, found > clock().addingTimeInterval(LiveReadingGate.futureTolerance) {
            log("ignoring the App Group's newest reading time \(found.ISO8601Format()): it is in the future")
            newest = nil
        }
        appGroupNewestAtLaunch = .some(newest)
        return newest
    }

    /// The latest `DT` (`"/Date(<ms since 1970>)/"`, docs/trio-bridge.md) in a `latestReadings`
    /// payload, whichever app wrote it.
    static func newestReadingDate(in payload: Data?) -> Date? {
        guard let payload, let elements = try? JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else { return nil }
        let dates = elements.compactMap { element -> Date? in
            guard let text = element["DT"] as? String,
                  let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close,
                  let milliseconds = Double(text[text.index(after: open)..<close]), milliseconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return dates.max()
    }

    /// Re-checks and retries a failed write without new readings (foreground, timer).
    func retry(session: SensorSession?) async {
        guard let bridge = activeBridge else { return }
        noteHold() // a hold's starvation is re-evaluated on every retry (foreground, ticker)
        await bridge.publish([], session: session)
    }

    /// The user turned the bridge off: remove this app's readings and the heartbeat keys from
    /// Trio's App Group (docs/trio-bridge.md "Heartbeat wiring").
    func removeEverythingFromTrio() async {
        guard let bridge, !summary.offWhileListening else { return }
        do throws(TrioBridgeError) {
            try await bridge.clear()
        } catch {
            log("clear failed: \(TrioBridgeSummary.describe(error))")
        }
        await writeHeartbeat(nil, on: bridge)
    }

    /// docs/trio-bridge.md "Heartbeat wiring": publish the sensor as Trio's heartbeat only while
    /// there is an authenticated pairing (`peripheral` non-nil) and the bridge is on; otherwise, with
    /// the bridge on, remove the keys (also stale ones another app left). With the bridge off this
    /// app does not touch Trio's App Group. Call after pairing, forgetting and every state change.
    func updateHeartbeat(_ desired: TrioHeartbeatPeripheral?) async {
        guard let bridge = activeBridge else { return }
        // Re-check the App Group every time rather than trusting what this process last wrote:
        // another app (an old xDrip4iOS install) may have written its heartbeat keys since
        // (Phase 2 review minor 8).
        let inGroup = await bridge.heartbeatAddressInAppGroup()
        let wanted = desired?.peripheralIdentifier.uuidString
        if heartbeatInSync, desired == heartbeatWritten, inGroup == wanted {
            return
        }
        if heartbeatInSync, inGroup != wanted {
            log("heartbeat address in Trio's App Group is \(inGroup ?? "none"), expected \(wanted ?? "none"): rewriting")
        }
        await writeHeartbeat(desired, on: bridge)
    }

    /// G7Kit's heartbeat target (the paired sensor's peripheral identifier, the G7 service and its
    /// Receive_Authentication characteristic, as xDrip4iOS 7.1.0 publishes them) in TrioBridge's form.
    static func heartbeatPeripheral(for target: G7HeartbeatTarget) -> TrioHeartbeatPeripheral {
        TrioHeartbeatPeripheral(peripheralIdentifier: target.peripheralIdentifier, serviceUUID: target.serviceUUID, receiveCharacteristicUUID: target.characteristicUUID)
    }

    private func writeHeartbeat(_ peripheral: TrioHeartbeatPeripheral?, on bridge: TrioBridge) async {
        do throws(TrioBridgeError) {
            try await bridge.setHeartbeatPeripheral(peripheral)
            heartbeatWritten = peripheral
            heartbeatInSync = true
            summary.heartbeatError = nil
        } catch {
            heartbeatInSync = false
            summary.heartbeatError = TrioBridgeSummary.describe(error)
            log("heartbeat \(peripheral == nil ? "removal" : "write") failed: \(summary.heartbeatError ?? "")")
        }
        summary.heartbeatPublished = heartbeatInSync && heartbeatWritten != nil
        summary.heartbeatAddressInAppGroup = await bridge.heartbeatAddressInAppGroup()
        onChange?(summary)
    }

    private func log(_ message: String) {
        diagnostics.record(DiagnosticEvent(date: clock(), category: .bridge, message: "Trio coordinator: " + message))
    }
}
