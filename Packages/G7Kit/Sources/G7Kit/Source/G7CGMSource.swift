// Original to Sensor (no ported code).

import Foundation
import GlucoseCore

/// Dexcom G7 10-day sensor in primary mode: this app pairs (J-PAKE with the 4-digit code),
/// authenticates on every ~5-minute connection, and publishes only valid readings (S2-S4).
///
/// Create exactly one, early in app launch (so CoreBluetooth state restoration can find its
/// central), then call `start(pairingCode: nil)`. Stream rules follow `CGMSource`: each stream is
/// created once with unbounded buffering, never finished, one consumer each.
///
/// Settings support: `pair(code:)`, `forgetSensor()`. There is no "stop session": xDrip4iOS
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

    // MARK: - Settings

    /// Pairs a new sensor: `start(pairingCode:)` with the code from the applicator.
    public func pair(code: String) async throws {
        try await start(pairingCode: code)
    }

    /// Stops, deletes the pairing code and key, and reports `.notPaired`.
    public func forgetSensor() async {
        await onQueue { self.controller.forget() }
    }

    /// The values Trio's heartbeat needs (see `G7HeartbeatTarget`), or nil when there is no
    /// authenticated pairing. Re-read it after `pair`, `forgetSensor` and whenever `state` changes;
    /// publish nil (remove the keys) when it is nil.
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
