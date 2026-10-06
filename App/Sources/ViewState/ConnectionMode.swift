// D45 listen mode and D47 raw packet recording: the screens' side, prepared before the G7Kit API
// (WS1) and the facade (Integrator A) exist. Every D45/D47 control hangs off an optional view state
// that stays nil until `AppServices` offers the feature; while it is nil every screen looks and
// behaves exactly as before D45. Wiring is then mapping only (docs/app-wiring.md "D45/D47").
//
// D45 (PROGRESS): listen mode only observes the BLE connection the Dexcom app on this phone
// authenticated — no pairing code, nothing written to the sensor (no auth, backfill, calibration or
// control commands). Readings pass the same gate (S2) and alerts work. While listening, the Trio
// handoff and Nightscout/Share uploads are forced off. Pairing this app (slot 2) is for the next
// sensor, after the Dexcom app is deleted.

import Foundation

/// How this app reaches the G7 sensor (D45).
enum SensorConnectionMode: String, CaseIterable, Identifiable, Sendable {
    /// Observe the Dexcom app's connection to the current sensor; send nothing.
    case listen
    /// This app is the sensor's primary device (the Dexcom app removed): pairing code, backfill,
    /// calibration, Trio handoff and uploads.
    case pair

    var id: String { rawValue }
}

/// D45 view state. Nil (on Settings, Onboarding and Now) until the facade offers listen mode.
struct ConnectionModeState: Equatable, Sendable {
    /// The mode in effect; in onboarding, nil until the person has chosen.
    var mode: SensorConnectionMode?

    var isListening: Bool { mode == .listen }
}

enum ConnectionModeText {
    /// The two choices (onboarding and Settings › Sensor), with one line each.
    static func title(_ mode: SensorConnectionMode) -> String {
        switch mode {
        case .listen: return "Listen alongside the Dexcom app (this sensor)"
        case .pair: return "Pair this app (Dexcom app removed)"
        }
    }

    static func explanation(_ mode: SensorConnectionMode) -> String {
        switch mode {
        case .listen:
            return "Keep the Dexcom app. This app reads the sensor through the Dexcom app's connection and sends it nothing: no code, no calibration, and Trio handoff and uploads stay off."
        case .pair:
            return "Delete the Dexcom app first. This app becomes the sensor's only connection: pairing code, calibration, Trio handoff and uploads."
        }
    }

    /// Short value for the Settings row.
    static func row(_ mode: SensorConnectionMode) -> String {
        switch mode {
        case .listen: return "listening alongside Dexcom"
        case .pair: return "paired with this app"
        }
    }

    /// The calm status line while listening (Now, Settings › Sensor). Not a warning: this is the
    /// chosen way of working.
    static let listeningStatus = "Listening — the Dexcom app owns the connection"

    /// Under the Trio and Nightscout/Share switches, which are off and disabled while listening.
    static let outputsOffWhileListening = "Off while listening alongside the Dexcom app"
    /// Settings rows for Trio, Nightscout and Dexcom Share while listening.
    static let outputsOffRow = "off while listening"

    /// Pairing-only actions, explained instead of offered while listening.
    static let calibrationWhileListening = "Calibrate in the Dexcom app: while listening, this app sends nothing to the sensor."
    static let pairingWhileListening = "Pairing isn't used while listening. To pair this app, delete the Dexcom app, then choose \u{201C}\(title(.pair))\u{201D}."
    static let sensorProblemWhileListening = "Check the sensor in the Dexcom app: it owns the connection while this app listens."

    /// Confirmation before switching modes in Settings.
    static func switchTitle(to mode: SensorConnectionMode) -> String {
        switch mode {
        case .listen: return "Listen alongside the Dexcom app?"
        case .pair: return "Pair this app with the sensor?"
        }
    }

    static func switchMessage(to mode: SensorConnectionMode) -> String {
        switch mode {
        case .listen:
            return "This app stops connecting to the sensor itself and only listens to the Dexcom app's connection. Trio handoff and uploads turn off while listening."
        case .pair:
            return "Delete the Dexcom app first: only one app can be the sensor's primary device. Then enter the sensor's 4-digit pairing code."
        }
    }

    /// Onboarding's listening step.
    static let onboardingWaiting = "Waiting for the Dexcom app's connection… The sensor talks to it about every 5 minutes; keep the Dexcom app installed and signed in."
    static let onboardingListening = "Listening. Readings arrive whenever the Dexcom app's sensor connects."
}

/// D45 rules the screens apply while listening. Pure; unit-tested.
enum ListenModeRules {
    /// The Now hero while listening: no pairing or calibration button (those write to the sensor);
    /// the detail says where to act instead. Anything else is unchanged.
    static func hero(_ hero: NowHero, listening: Bool) -> NowHero {
        guard listening, case .message(let title, let detail, let action?) = hero else { return hero }
        switch action {
        case .calibrate:
            return .message(title: title, detail: "\(detail) \(ConnectionModeText.calibrationWhileListening)", action: nil)
        case .pairSensor, .pairAgain:
            return .message(title: title, detail: "\(detail) \(ConnectionModeText.sensorProblemWhileListening)", action: nil)
        }
    }

    /// A Settings row for an output (Trio, Nightscout, Dexcom Share): forced off while listening.
    static func outputRow(_ value: String, listening: Bool) -> String {
        listening ? ConnectionModeText.outputsOffRow : value
    }
}

/// D47: Settings › Diagnostics "Record raw glucose packets". Nil until the facade offers it.
struct PacketRecordingState: Equatable, Sendable {
    var isOn: Bool
}

enum PacketRecordingText {
    static let title = "Record raw glucose packets"
    /// One line (D47: off by default; for capturing a real LOW/HIGH, D31).
    static let explanation = "Adds the bytes of every glucose message from the sensor to the diagnostic log, to capture a real LOW or HIGH for checking. Off by default; turn it off when done."
}
