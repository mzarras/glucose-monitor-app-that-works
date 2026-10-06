// Original to Sensor (no ported code).

import Foundation
import GlucoseCore

/// Dexcom G7 10-day sensor. In primary mode this app pairs (J-PAKE with the 4-digit code),
/// authenticates on every ~5-minute connection, and publishes only valid readings (S2-S4).
///
/// Create exactly one, early in app launch (so CoreBluetooth state restoration can find its
/// central), then call `start(pairingCode: nil)`. Stream rules follow `CGMSource`: each stream is
/// created once with unbounded buffering, never finished, one consumer each.
///
/// Two modes (D45, `G7ConnectionMode`): primary (above) and listen, where the Dexcom app on the
/// same phone owns the connection and this source only observes it — no pairing code, no writes to
/// the sensor; start it with `start(pairingCode: nil)` after choosing `.listen`.
///
/// Settings support: `pair(code:)` (a new sensor), `pairAgain(code:)` (the same sensor, after it
/// refused this phone), `forgetSensor()`. There is no "stop session": xDrip4iOS
/// 7.1.0 primary mode sends no session-stop command for the G7 (its `CGMG7Transmitter` has none;
/// LoopKit G7SensorKit declares opcode 0x28 in G7Opcode.swift:13 but never sends it), so there is
/// nothing verified to port. `supportsStopSession` is false.
public final class G7CGMSource: CalibratingCGMSource, @unchecked Sendable {
    // `@unchecked Sendable`: every stored property is a `let`. The non-Sendable ones (`controller`,
    // `central`) are only used on `queue`: CoreBluetooth delivers its callbacks on `queue`, and
    // every public method below hops onto `queue` before touching them. The continuations are
    // Sendable and may be yielded from `queue`.

    public static let supportsStopSession = false

    public let readings: AsyncStream<GlucoseReading>
    public let state: AsyncStream<SensorState>
    public let calibrationUpdates: AsyncStream<CalibrationUpdate>

    private let queue: DispatchQueue
    private let controller: G7Controller
    private let central: AnyObject

    /// - Parameters:
    ///   - credentialStore: where the pairing code and J-PAKE key live; use the Keychain store in
    ///     the app (the default).
    ///   - diagnostics: receives BLE, auth and reading decisions (never the code or the key).
    ///   - clock: the phone clock; injected for tests.
    public convenience init(
        configuration: G7Configuration = G7Configuration(),
        credentialStore: G7CredentialStore = G7KeychainCredentialStore(),
        diagnostics: DiagnosticLog,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(configuration: configuration, credentialStore: credentialStore, diagnostics: diagnostics, clock: clock) { queue, controller in
            G7CoreBluetoothCentral(queue: queue, controller: controller, restoreIdentifier: configuration.restoreIdentifier) { message in
                diagnostics.record(DiagnosticEvent(date: clock(), category: .ble, message: "G7: " + message))
            }
        }
    }

    /// Designated initializer; tests inject a central that is not CoreBluetooth.
    init(
        configuration: G7Configuration,
        credentialStore: G7CredentialStore,
        diagnostics: DiagnosticLog,
        clock: @escaping @Sendable () -> Date,
        makeCentral: (DispatchQueue, G7Controller) -> G7CentralDriving
    ) {
        let (readings, readingsContinuation) = AsyncStream.makeStream(of: GlucoseReading.self, bufferingPolicy: .unbounded)
        let (state, stateContinuation) = AsyncStream.makeStream(of: SensorState.self, bufferingPolicy: .unbounded)
        let (calibrationUpdates, calibrationContinuation) = AsyncStream.makeStream(of: CalibrationUpdate.self, bufferingPolicy: .unbounded)
        self.readings = readings
        self.state = state
        self.calibrationUpdates = calibrationUpdates
        let queue = DispatchQueue(label: "com.mzarras.sensor.g7kit.bluetooth")
        let controller = G7Controller(
            store: credentialStore,
            diagnostics: diagnostics,
            now: clock,
            slot: configuration.authenticationSlot,
            mode: configuration.mode,
            recordsRawGlucosePackets: configuration.recordsRawGlucosePackets,
            output: G7Controller.Output(
                reading: { readingsContinuation.yield($0) },
                state: { stateContinuation.yield($0) },
                calibration: { calibrationContinuation.yield($0) }
            )
        )
        // The first state is emitted before the central exists, so it precedes every Bluetooth event.
        queue.sync { controller.emitInitialState() }
        // Created off `queue` so CoreBluetooth's initializer can never wait on it. Callbacks that
        // arrive before `controller.central` is set find the controller not running (start() has not
        // been called), so they need no central.
        let madeCentral = makeCentral(queue, controller)
        queue.sync { controller.central = madeCentral }
        self.queue = queue
        self.controller = controller
        self.central = madeCentral
    }

    // MARK: - CGMSource

    public var currentSession: SensorSession? {
        get async { await onQueue { self.controller.currentSession } }
    }

    /// Resumes the stored pairing (`pairingCode == nil`) or pairs a new sensor with its 4-digit code.
    /// Throws `G7StartError`.
    public func start(pairingCode: String?) async throws {
        let result = await onQueue { () -> Result<Void, G7StartError> in
            do throws(G7StartError) {
                try self.controller.start(pairingCode: pairingCode)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    /// Stops scanning and connecting. The streams stay open; `start` resumes on the same streams.
    public func stop() async {
        await onQueue { self.controller.stop() }
    }

    // MARK: - Mode (D45) and raw recording (D47)

    /// Primary (this app pairs and owns the connection) or listen (the Dexcom app owns it; this app
    /// only observes). See `G7ConnectionMode`.
    public var mode: G7ConnectionMode {
        get async { await onQueue { self.controller.mode } }
    }

    /// Switches mode — the app's explicit choice; G7Kit never switches by itself. Stops, drops every
    /// stored pairing and session (code, key, followed sensor, session start and end), and reports
    /// `.notPaired` (primary) or `.searching` (listen). Then call `start(pairingCode: nil)` for
    /// listen, or `pair(code:)` for primary. The app persists the choice and passes it as
    /// `G7Configuration.mode` at the next launch. Throws `G7StartError.credentialStoreFailed` when the
    /// stored pairing cannot be deleted (nothing switched).
    public func setMode(_ mode: G7ConnectionMode) async throws {
        let result = await onQueue { () -> Result<Void, G7StartError> in
            do throws(G7StartError) {
                try self.controller.setMode(mode)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    /// Calibration needs primary mode (listen mode never writes to the sensor; `submitCalibration`
    /// refuses with `.notAuthenticated` there).
    public var supportsCalibration: Bool {
        get async { await onQueue { self.controller.mode != .listen } }
    }

    /// D47 (Settings › Diagnostics): when on, the hex of every received glucose packet (`0x4E`; in
    /// listen mode also `0x31` and `0x25`), valid ones included, goes to the diagnostic log with its
    /// time. Off by default.
    public func setRecordsRawGlucosePackets(_ enabled: Bool) async {
        await onQueue { self.controller.recordsRawGlucosePackets = enabled }
    }

    // MARK: - Settings

    /// Pairs a new sensor: `start(pairingCode:)` with the code from the applicator. Primary mode only
    /// (`G7StartError.notAvailableInListenMode`).
    public func pair(code: String) async throws {
        try await start(pairingCode: code)
    }

    /// Pairs the stored sensor again with a full J-PAKE (D37): use after `.failed` with kind
    /// `.pairingRejected` or `.pairingCodeNeeded` for the sensor being worn. Keeps the sensor's identity
    /// and session; replaces the code and, once the sensor confirms, the key. Throws `G7StartError`
    /// (`.noSensorToPairAgain` when this phone never connected to a sensor: use `pair(code:)`).
    public func pairAgain(code: String) async throws {
        let result = await onQueue { () -> Result<Void, G7StartError> in
            do throws(G7StartError) {
                try self.controller.pairAgain(pairingCode: code)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    /// True when a sensor this phone has authenticated to is stored: route a code retry to
    /// `pairAgain(code:)` (the same sensor), otherwise to `pair(code:)` (a first or new sensor). In
    /// particular, a retry after the sensor authenticated during onboarding must use `pairAgain`:
    /// `pair(code:)` treats the stored sensor as the previous one (its refusal is skipped, §2.2).
    /// Always false in listen mode (no pairing there).
    public var hasStoredSensor: Bool {
        get async { await onQueue { self.controller.hasStoredSensor } }
    }

    /// The stored sensor's serial ("DXCMxx-" + 8 hex of the iOS identifier), nil when none is stored.
    /// In listen mode: the sensor whose authenticated connection was observed (same serial as primary
    /// mode would give).
    public var storedSensorSerial: String? {
        get async { await onQueue { self.controller.storedSensorSerial } }
    }

    /// Audit m1: tell G7Kit the newest reading the app has durably stored for the sensor `serial`
    /// (use `storedSensorSerial`; pass nil when none of that sensor's readings is stored). Call it as
    /// soon as the store is readable at launch, and again after each successful store write of this
    /// source's readings. Backfill records the sensor sends for later sensor times are then published
    /// again even if they were delivered before (e.g. delivered while the store was failing, then the
    /// app was terminated), with the same id and date as the first delivery and `isBackfill = true`;
    /// dedupe by id. A floor that is too low only causes such duplicates; without any call, nothing
    /// already delivered is re-published. The G7 decides which records it backfills (there is no
    /// backfill request), so only records it sends again are recovered (docs/g7-protocol.md §5.6).
    public func setLatestStoredReading(_ reading: GlucoseReading?, forSerial serial: String) async {
        await onQueue { self.controller.setLatestStoredReading(reading, serial: serial) }
    }

    /// Stops, deletes the pairing code and key, and reports `.notPaired`.
    public func forgetSensor() async {
        await onQueue { self.controller.forget() }
    }

    /// The values Trio's heartbeat needs (see `G7HeartbeatTarget`), or nil when there is no
    /// authenticated pairing — always nil in listen mode (D45: the Trio handoff is off there). Re-read
    /// it after `pair`, `forgetSensor`, `setMode` and whenever `state` changes; publish nil (remove the
    /// keys) when it is nil.
    public var heartbeatTarget: G7HeartbeatTarget? {
        get async { await onQueue { self.controller.heartbeatTarget } }
    }

    // MARK: - CalibratingCGMSource

    /// 40...400 mg/dL (CGMG7Transmitter.swift:1967-1974), see G7CalibrationQueue.
    public var acceptedCalibrationRange: ClosedRange<Int> { G7CalibrationQueue.acceptedRange }

    public func submitCalibration(_ request: CalibrationRequest) async throws(CalibrationRefusal) {
        let result = await onQueue { () -> Result<Void, CalibrationRefusal> in
            do throws(CalibrationRefusal) {
                try self.controller.submitCalibration(request)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    // MARK: - Private

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Tests: run `body` synchronously on the source's queue with the controller.
    func withController<T>(_ body: (G7Controller) -> T) -> T {
        queue.sync { body(controller) }
    }
}
