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
    private var statusTask: Task<Void, Never>?
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
                self.summary.update(from: status, now: Date())
                self.onChange?(self.summary)
            }
        }
    }

    /// The user's switch and the D20 DEBUG switch (always true in Release).
    func configure(enabled: Bool, liveOutputsAllowed: Bool) {
        summary.isEnabled = enabled
        summary.liveOutputsAllowed = liveOutputsAllowed
        onChange?(summary)
    }

    /// The bridge the pipeline should write to: nil while off, not allowed, or unavailable.
    var activeBridge: TrioBridge? {
        summary.isEnabled && summary.liveOutputsAllowed ? bridge : nil
    }

    /// Hands recent stored readings to the bridge (launch re-seed and switching it on). Every one
    /// passes the gate again inside the bridge; only `.sensor` readings are offered (S6).
    func reseed(with readings: [GlucoseReading], session: SensorSession?) async {
        guard let bridge = activeBridge else { return }
        let live = readings.filter { $0.source.isLiveSensor }
        let result = await bridge.publish(live, session: session)
        log("re-seeded with \(live.count) stored sensor reading(s): \(result.addedReadingIDs.count) written, \(result.refusals.count) refused")
    }

    /// Re-checks and retries a failed write without new readings (foreground, timer).
    func retry(session: SensorSession?) async {
        guard let bridge = activeBridge else { return }
        await bridge.publish([], session: session)
    }

    /// The user turned the bridge off: remove this app's readings and the heartbeat keys from
    /// Trio's App Group (docs/trio-bridge.md "Heartbeat wiring").
    func removeEverythingFromTrio() async {
        guard let bridge else { return }
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
        guard !heartbeatInSync || desired != heartbeatWritten else { return }
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
        diagnostics.record(DiagnosticEvent(date: Date(), category: .bridge, message: "Trio coordinator: " + message))
    }
}
