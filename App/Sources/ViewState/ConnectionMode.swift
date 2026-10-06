// D45 listen mode and D47 raw packet recording: the screens' side. `AppModel` maps the facade's
// `connectionMode`, `recordsRawGlucosePackets` and the outputs' `offWhileListening` into these view
// states (docs/app-wiring.md "D45/D47"); a fixture model or preview without them (nil) shows every
// screen as before D45.
//
// D45 (PROGRESS): listen mode only observes the BLE connection the Dexcom app on this phone
// authenticated — no pairing code, nothing written to the sensor (no auth, backfill, calibration or
// control commands). Readings pass the same gate (S2) and alerts work. While listening, the Trio
// handoff and Nightscout/Share uploads are forced off. Pairing this app (slot 2) is for the next
// sensor, after the Dexcom app is deleted.

import Foundation
import GlucoseCore
import WidgetCore

/// How this app reaches the G7 sensor (D45). Also the facade's `AppServices.connectionMode`.
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

    /// Short value for the Settings row (nil: not chosen yet).
    static func row(_ mode: SensorConnectionMode?) -> String {
        switch mode {
        case .listen: return "listening alongside Dexcom"
        case .pair: return "paired with this app"
        case nil: return "not chosen yet"
        }
    }

    /// Before every pairing-code field (onboarding, Settings › Sensor) and in the switch to pairing:
    /// pairing evicts the Dexcom app on this phone from the sensor (they share the slot).
    static let pairingTakeoverWarning = "Pairing takes over the sensor's connection: the Dexcom app on this phone will stop receiving readings. Delete the Dexcom app first."

    /// Settings › Sensor before a choice: no code field until "Pair this app" is chosen.
    static let chooseFirst = "Choose how this app connects before pairing anything. If the Dexcom app is on this phone, listen alongside it."

    /// Listen mode: forgetting the followed sensor is how the app follows another one (G7Kit §14).
    static let stopFollowingButton = "Stop following this sensor"
    static let stopFollowingTitle = "Stop following this sensor?"
    static let stopFollowingMessage = "This app forgets this sensor and its readings stop here. It then follows the next sensor the Dexcom app connects to, for example after you start a new one. The Dexcom app isn't affected."
    static let stopFollowingNote = "After this sensor ends, start the new one in the Dexcom app, then stop following this one here so this app follows the new one."

    /// The Now hero before the person has chosen listen or pair.
    static let notSetUpTitle = "No sensor set up"
    static let notSetUpDetail = "Choose how this app connects: listen alongside the Dexcom app on this phone, or pair this app with the Dexcom app removed."

    /// The Now hero and state line while listening and no sensor is followed.
    static let notFollowingTitle = "Not following a sensor"
    static let notFollowingDetail = "Listening for the Dexcom app's connection to a sensor. Readings start once the Dexcom app connects to one."
    static let notFollowingStateLine = "NOT FOLLOWING A SENSOR"

    /// The calm status line while listening (Now, Settings › Sensor). Not a warning: this is the
    /// chosen way of working.
    static let listeningStatus = "Listening — the Dexcom app owns the connection"

    /// Under the Trio and Nightscout/Share switches, which are off and disabled while listening.
    static let outputsOffWhileListening = "Off while listening alongside the Dexcom app"
    /// Settings rows for Trio, Nightscout and Dexcom Share while listening.
    static let outputsOffRow = "off while listening"

    /// Pairing-only actions, explained instead of offered while listening.
    static let calibrationWhileListening = "Calibrate in the Dexcom app: while listening, this app sends nothing to the sensor."
    static let pairingWhileListening = "Pairing isn't used while listening. To pair this app, delete the Dexcom app, then choose \u{201C}\(title(.pair))\u{201D} under Connection in Settings \u{203A} Sensor."
    static let sensorProblemWhileListening = "Check the sensor in the Dexcom app: it owns the connection while this app listens."

    /// Confirmation before switching modes in Settings.
    static func switchTitle(to mode: SensorConnectionMode) -> String {
        switch mode {
        case .listen: return "Listen alongside the Dexcom app?"
        case .pair: return "Pair this app with the sensor?"
        }
    }

    static func switchButton(to mode: SensorConnectionMode) -> String {
        mode == .listen ? "Listen alongside the Dexcom app" : "Pair this app"
    }

    static func switchMessage(to mode: SensorConnectionMode) -> String {
        switch mode {
        case .listen:
            return "This app stops connecting to the sensor itself and only listens to the Dexcom app's connection. Trio handoff and uploads turn off while listening."
        case .pair:
            return "\(pairingTakeoverWarning) Then enter the sensor's 4-digit pairing code."
        }
    }

    /// Why `setConnectionMode(_:)` did not switch; nothing changed in every case.
    static func errorText(_ error: ConnectionModeError) -> String {
        switch error {
        case .replayActive:
            return "A replay is running, so the connection can't change. Stop the replay (Settings › Developer) first. Nothing changed."
        case .couldNotSave(let message):
            return "The connection choice couldn't be saved, so nothing changed. \(message)"
        case .credentialStoreFailed(let message):
            return "The sensor's stored connection couldn't be changed, so nothing changed. Unlock the phone and try again. \(message)"
        }
    }

    /// Shown while a switch is on its way.
    static let switching = "Changing how the app connects…"

    /// Onboarding's listening step.
    static let onboardingWaiting = "Waiting for the Dexcom app's connection… The sensor talks to it about every 5 minutes; keep the Dexcom app installed and signed in."
    static let onboardingListening = "Listening. Readings arrive whenever the Dexcom app's sensor connects."
}

/// A listen-mode sensor failure in the person's words (S5: it stays on screen as a banner and in
/// Settings › Sensor until it clears).
struct ListenFailureText: Equatable, Sendable {
    let title: String
    let detail: String
    /// Lower-case word for the SENSOR rows.
    let row: String
}

/// D45 rules the screens apply while listening. Pure; unit-tested.
enum ListenModeRules {
    /// G7Kit's three transient listen-mode failures (`G7FailureReason.listen…`), recognised by kind
    /// while listening (D36: decisions from the kind). Nil for anything else, which keeps its usual
    /// wording.
    static func failure(_ failure: SensorFailure, listening: Bool) -> ListenFailureText? {
        guard listening else { return nil }
        switch failure.kind {
        case .sessionLengthUnknown:
            return ListenFailureText(
                title: "Waiting for session details",
                detail: "Waiting for the sensor's session details. They come from the Dexcom app's (or Trio's) connection within a few readings; readings are held back until then.",
                row: "waiting for session details")
        case .authenticationFailed:
            return ListenFailureText(
                title: "Connection not confirmed",
                detail: "Can't confirm the Dexcom app's connection to the sensor is authenticated, so no readings are used until it is. Keep the Dexcom app installed, signed in and running.",
                row: "connection not confirmed")
        case .rejectedAfterAuthentication:
            return ListenFailureText(
                title: "Sensor rejected the connection",
                detail: "The sensor rejected the Dexcom app's connection, so readings from this sensor wake aren't used. The next wake, within about 5 minutes, is checked again.",
                row: "connection rejected")
        default:
            return nil
        }
    }

    /// The Now hero while listening: no pairing or calibration button (those write to the sensor);
    /// the detail says where to act instead — for an ended sensor, how to follow the new one. No
    /// followed sensor reads "Not following a sensor". Anything else is unchanged.
    /// - Parameter chosen: false until the person has chosen listen or pair: no sensor then reads
    ///   "No sensor set up" with "Set up the sensor" (the choice), never "Pair a sensor".
    static func hero(_ hero: NowHero, display: GlucoseDisplayState, listening: Bool, chosen: Bool = true) -> NowHero {
        if !chosen, case .notPaired = display, case .message(_, _, .pairSensor?) = hero {
            return .message(title: ConnectionModeText.notSetUpTitle, detail: ConnectionModeText.notSetUpDetail, action: .setUpSensor)
        }
        guard listening else { return hero }
        if case .notPaired = display {
            return .message(title: ConnectionModeText.notFollowingTitle, detail: ConnectionModeText.notFollowingDetail, action: nil)
        }
        guard case .message(let title, let detail, let action?) = hero else { return hero }
        switch action {
        case .calibrate:
            return .message(title: title, detail: "\(detail) \(ConnectionModeText.calibrationWhileListening)", action: nil)
        case .pairSensor:
            // An ended sensor (expired, replace): the new one starts in the Dexcom app.
            return .message(title: title, detail: "\(detail) \(ConnectionModeText.stopFollowingNote)", action: nil)
        case .pairAgain, .setUpSensor:
            return .message(title: title, detail: "\(detail) \(ConnectionModeText.sensorProblemWhileListening)", action: nil)
        }
    }

    /// The Now state line while listening with no followed sensor.
    static func stateLine(_ line: StateLine, display: GlucoseDisplayState, listening: Bool) -> StateLine {
        guard listening, case .notPaired = display else { return line }
        return StateLine(text: ConnectionModeText.notFollowingStateLine, dot: line.dot)
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
