// D45 listen mode and D47 raw packet recording: the screens' side. `AppModel` maps the facade's
// `connectionMode`, `recordsRawGlucosePackets` and the outputs' `offWhileListening` into these view
// states (docs/app-wiring.md "D45/D47"); a fixture model or preview without them (nil) shows every
// screen as before D45.
//
// D45 (PROGRESS): listen mode only observes the BLE connection the Dexcom app on this phone
// authenticated — no pairing code, no auth, backfill, calibration or control commands; the only
// write is, if needed, one read-only session-length question per connection (D49/D50, as Trio's
// G7SensorKit asks). Readings pass the same gate (S2) and alerts work. While listening, the Trio
// handoff and Nightscout/Share uploads are forced off. Pairing this app (slot 2) is for the next
// sensor, after the Dexcom app is deleted.

import Foundation
import GlucoseCore
import WidgetCore

/// How this app reaches the G7 sensor (D45). Also the facade's `AppServices.connectionMode`.
enum SensorConnectionMode: String, CaseIterable, Identifiable, Sendable {
    /// Observe the Dexcom app's connection to the current sensor; at most one read-only
    /// session-length question per connection (D49/D50).
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
            return "Keep the Dexcom app. This app reads the sensor through the Dexcom app's connection and sends it nothing except, if needed, one read-only question for the session length (the same one Trio asks). No code, no calibration; Trio handoff and uploads stay off."
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

    /// Settings › Sensor when the saved choice can't be used (`ConnectionSettingProblem`).
    static let chooseAgain = "Choose Listen or Pair again below; until then this app doesn't connect to the sensor."

    /// Settings › Sensor before a choice: no code field until "Pair this app" is chosen.
    static let chooseFirst = "Choose how this app connects before pairing anything. If the Dexcom app is on this phone, listen alongside it."

    /// Listen mode: forgetting the followed sensor is how the app follows another one (G7Kit §14).
    static let stopFollowingButton = "Stop following this sensor"
    static let stopFollowingTitle = "Stop following this sensor?"
    static let stopFollowingMessage = "This app forgets this sensor and its readings stop here. It then follows the next sensor the Dexcom app connects to, for example after you start a new one. The Dexcom app isn't affected."
    static let stopFollowingNote = "After this sensor ends, start the new one in the Dexcom app, then stop following this one here so this app follows the new one."

    /// The Now hero before the person has chosen listen or pair.
    static let notSetUpTitle = "No sensor set up"
    static let notSetUpStateLine = "NO SENSOR SET UP"
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
    static let calibrationWhileListening = "Calibrate in the Dexcom app: while listening, this app doesn't calibrate the sensor."
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
    /// "Stop following this sensor" is offered only while a sensor is followed (its serial is known,
    /// from the session or G7Kit's followed sensor). After it the services look for the next sensor at
    /// once (`LiveAppServices.forgetSensor`), so the state goes back to searching rather than staying
    /// "not paired": the state cannot tell whether there is anything left to stop following.
    static func offersStopFollowing(_ sensor: SensorSettings) -> Bool {
        sensor.serial != nil
    }

    /// Every failure kind whose source wording would be wrong for a listening person (it says to pair,
    /// or names this app's own connection), in listen words, recognised by kind (D36: decisions from
    /// the kind). Kinds reachable in listen mode (G7Controller, G7ReadingPipeline): sessionLengthUnknown,
    /// authenticationFailed, rejectedAfterAuthentication (the three `G7FailureReason.listen…`),
    /// credentialsUnavailable, clockMismatch, noGlucoseValue, unsupportedSensor, sensorFailed,
    /// sessionStopped. The pairing kinds and otherAppRejected are primary-only today; they are covered
    /// so none can ever tell a listening person to pair. Nil keeps the source's wording (clock,
    /// glucose value, an ended sensor: `endedSensorDetail` adds how to follow the new one).
    static func failure(_ failure: SensorFailure, listening: Bool) -> ListenFailureText? {
        guard listening else { return nil }
        switch failure.kind {
        case .credentialsUnavailable:
            return ListenFailureText(
                title: "Waiting for the phone to unlock",
                detail: "Waiting for the phone to unlock — readings resume after you unlock it.",
                row: "waiting for unlock")
        case .otherAppRejected:
            return ListenFailureText(
                title: "Connection interrupted",
                detail: "Another app on this phone seems to be connecting to the sensor and being refused, which cuts connections short. Close other apps that connect to G7 sensors (xDrip4iOS, Trio's or Loop's own G7 connection); keep the Dexcom app.",
                row: "connection interrupted")
        case .pairingRejected, .pairingCodeNeeded, .bondRemoved, .bluetoothPairingIncomplete:
            return ListenFailureText(
                title: "Sensor not reachable",
                detail: "The sensor isn't accepting the connection this app listens to. Check the sensor in the Dexcom app; nothing needs pairing here.",
                row: "check the Dexcom app")
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
        if case .sensorFailed(let failure, _) = display {
            if let text = Self.failure(failure, listening: true) {
                return .message(title: text.title, detail: text.detail, action: nil)
            }
            if failure.requiresSensorReplacement {
                return .message(title: "Replace the sensor", detail: endedSensorDetail(failure.message), action: nil)
            }
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

    /// An ended sensor while listening: the source's words, then how to go on (the new sensor starts
    /// in the Dexcom app; this app follows it once this one is no longer followed).
    static func endedSensorDetail(_ failureMessage: String) -> String {
        "\(failureMessage) Start the new sensor in the Dexcom app, then stop following this one in Settings \u{203A} Sensor."
    }

    /// A failure's words for a listening person: listen wording, an ended sensor with how to go on,
    /// or the source's own message.
    static func listeningDetail(_ failure: SensorFailure) -> String {
        if let text = Self.failure(failure, listening: true) { return text.detail }
        if failure.requiresSensorReplacement { return endedSensorDetail(failure.message) }
        return failure.message
    }

    /// The Now state line with no sensor: "NO SENSOR SET UP" before a choice (as the hero, P3 review
    /// n5), "NOT FOLLOWING A SENSOR" while listening.
    static func stateLine(_ line: StateLine, display: GlucoseDisplayState, listening: Bool, chosen: Bool = true) -> StateLine {
        // P3b nit: "PAIR THE SENSOR AGAIN" (and the like) in listen words while listening.
        if listening, case .sensorFailed(let failure, _) = display, let text = Self.failure(failure, listening: true) {
            return StateLine(text: text.title.uppercased(), dot: line.dot)
        }
        guard case .notPaired = display else { return line }
        if !chosen, line.text == "NO SENSOR PAIRED" { return StateLine(text: ConnectionModeText.notSetUpStateLine, dot: line.dot) }
        guard listening else { return line }
        return StateLine(text: ConnectionModeText.notFollowingStateLine, dot: line.dot)
    }

    /// A Settings row for an output (Trio, Nightscout, Dexcom Share): forced off while listening.
    static func outputRow(_ value: String, listening: Bool) -> String {
        listening ? ConnectionModeText.outputsOffRow : value
    }
}

/// Why the connection setting can't be trusted (`AppServices.connectionSettingProblem`), from the
/// services' message: the saved file couldn't be read, a stored sensor connection of the other mode
/// was kept (G7Kit's deletion refused), or a failed switch couldn't save the previous setting back.
/// Recognised by the services' wording (LiveAppServices+Connection.swift, SensorConnectionSettings
/// .swift); anything else reads as the generic "can't be used".
struct ConnectionSettingProblem: Equatable, Sendable {
    enum Cause: Equatable, Sendable { case unreadable, refusedDeletion, failedSave, other }

    let cause: Cause

    init(_ message: String) {
        if message.hasPrefix("The saved connection setting does not match the stored sensor connection") {
            cause = .refusedDeletion
        } else if message.hasPrefix("The connection mode could not be changed and the previous setting could not be saved back") {
            cause = .failedSave
        } else if message.contains("could not be read") {
            cause = .unreadable
        } else {
            cause = .other
        }
    }

    var title: String {
        switch cause {
        case .unreadable: return "Connection setting couldn't be read"
        case .refusedDeletion: return "Connection setting doesn't match the sensor"
        case .failedSave: return "Connection setting couldn't be saved"
        case .other: return "Connection setting can't be used"
        }
    }

    /// One sentence on what happened (the banner and Settings › Sensor).
    var explanation: String {
        switch cause {
        case .unreadable:
            return "The saved choice between listening and pairing couldn't be read."
        case .refusedDeletion:
            return "The saved choice doesn't match the sensor connection stored on this phone, so that connection was kept rather than deleted."
        case .failedSave:
            return "Changing how the app connects failed, and the previous choice couldn't be saved back."
        case .other:
            return "The saved choice between listening and pairing can't be used."
        }
    }
}

/// D47: Settings › Diagnostics "Record raw glucose packets". Nil until the facade offers it.
struct PacketRecordingState: Equatable, Sendable {
    var isOn: Bool
    /// The connection setting is unresolved: a change applies to this run only (the services don't
    /// write the setting until Listen or Pair is chosen again).
    var unresolved: Bool = false
}

enum PacketRecordingText {
    static let title = "Record raw glucose packets"
    /// One line (D47: off by default; for capturing a real LOW/HIGH, D31).
    static let explanation = "Adds the bytes of every glucose message from the sensor to the diagnostic log, to capture a real LOW or HIGH for checking. Off by default; turn it off when done."
    /// While the connection setting is unresolved.
    static let unresolvedNote = "Until Listen or Pair is chosen again, a change here lasts only until the app restarts."
}
