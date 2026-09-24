// The composition root (HANDOFF §9.3 Phase 2; docs/architecture.md "Composition"). Builds exactly
// one of each long-lived object for the process and hands the UI one `AppServices`:
//
//   G7CGMSource (restore id com.mzarras.sensor.g7kit.central, created during launch)
//   GlucoseStore  production, Application Support/GlucoseStore/readings.sqlite (D25) — opened at bootstrap
//   AlertService  UNUserNotificationCenter adapter, audio player, AlarmKit adapter with the app's
//                 StopUrgentLowAlarmIntent (D26); the intent bridge is connected at bootstrap
//   TrioBridge    Trio's App Group from Info.plist TrioAppGroupID, LOW/HIGH per D21 (TrioCoordinator)
//   ReadingUploader ×2  Nightscout and Dexcom Share, queues in Application Support/Uploads (UploadCoordinator)
//   KeychainCredentialStore (NightscoutKit) and G7KeychainCredentialStore (G7Kit's default)
//   WidgetSnapshotPublisher (App Group group.com.mzarras.sensor)
//   History importers + UserDefaultsNightscoutImportCheckpointStore (on demand)
//   RingBufferDiagnosticLog, saved to Application Support/Diagnostics
//
// DEBUG: a unit-test host gets an inert `PreviewAppServices` (tests build their own pipelines);
// `-replayScenario <name>` starts a replay run at launch (B's UI tests).

import AlertEngine
import Foundation
import G7Kit
import GlucoseCore
import NightscoutKit
import SwiftUI
import TrioBridge
import UIKit
import WidgetCore

@MainActor
final class AppEnvironment {
    /// Created on first use, which the app delegate makes happen during launch (willFinishLaunching),
    /// so the G7 source's CoreBluetooth central exists before launch finishes (state restoration).
    static let shared = AppEnvironment.make()

    /// What the UI talks to.
    let services: any AppServices
    /// The live services, nil in a unit-test host.
    private let live: LiveAppServices?

    private init(services: any AppServices, live: LiveAppServices?) {
        self.services = services
        self.live = live
    }

    static func make(arguments: [String] = ProcessInfo.processInfo.arguments, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        #if DEBUG
        if environment["XCTestConfigurationFilePath"] != nil {
            return AppEnvironment(services: PreviewAppServices(), live: nil)
        }
        #endif
        let live = makeLive(arguments: arguments)
        return AppEnvironment(services: live, live: live)
    }

    private static func makeLive(arguments: [String]) -> LiveAppServices {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let diagnostics = RingBufferDiagnosticLog(fileURL: support.appendingPathComponent("Diagnostics/diagnostics.json"))

        // First, so CoreBluetooth can restore its central during this launch (HANDOFF §4.6).
        let g7 = G7CGMSource(diagnostics: diagnostics)

        let credentials = KeychainCredentialStore()
        let trioGroupID = (Bundle.main.object(forInfoDictionaryKey: "TrioAppGroupID") as? String).flatMap { $0.isEmpty ? nil : $0 }
        let trio = TrioCoordinator(
            appGroupID: trioGroupID,
            store: trioGroupID.map { AppGroupUserDefaultsStore(appGroupID: $0) },
            diagnostics: diagnostics
        )
        let uploads = UploadCoordinator(
            credentials: credentials, queueDirectory: support.appendingPathComponent("Uploads"),
            deviceName: AppIdentity.displayName, diagnostics: diagnostics
        )
        let alarms = SystemAlarmAdapter(makeStopIntent: {
            if #available(iOS 26.0, *) { return StopUrgentLowAlarmIntent() }
            return nil
        })
        let ports = AlertPorts(
            notificationCenter: UserNotificationCenterAdapter(), audio: PlaybackAlertAudioPlayer(), alarms: alarms,
            configuration: AlertEngineConfiguration(), diagnostics: diagnostics
        )
        let widget = WidgetSnapshotPublisher.appGroup().map { LiveWidgetPublisher(publisher: $0, accent: .default, diagnostics: diagnostics) }
        if widget == nil {
            diagnostics.record(DiagnosticEvent(date: Date(), category: .app, message: "widget snapshot disabled: the App Group container is not available to this build"))
        }
        if trioGroupID == nil {
            diagnostics.record(DiagnosticEvent(date: Date(), category: .bridge, message: "Info.plist has no TrioAppGroupID: the Trio bridge cannot be used"))
        }
        return LiveAppServices(LiveAppServices.Dependencies(
            g7: g7, diagnostics: diagnostics, preferences: AppPreferences(), credentials: credentials, trio: trio, uploads: uploads,
            alertPorts: ports, widget: widget, databaseURL: support.appendingPathComponent("GlucoseStore/readings.sqlite"),
            httpTransport: URLSessionTransport(), launchReplay: launchReplay(arguments)
        ))
    }

    /// DEBUG: `-replayScenario <name>` [`-replaySpeed <x>`] [`-replayStartMinute <m>`]. Nil in Release.
    static func launchReplay(_ arguments: [String]) -> LiveAppServices.LaunchReplay? {
        #if DEBUG
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let scenario = value(after: "-replayScenario") else { return nil }
        return LiveAppServices.LaunchReplay(
            scenario: scenario,
            speed: value(after: "-replaySpeed").flatMap(Double.init) ?? 1,
            startMinute: value(after: "-replayStartMinute").flatMap(Double.init) ?? 0
        )
        #else
        return nil
        #endif
    }

    // MARK: - Lifecycle hooks (from the app delegate and the scene)

    func didFinishLaunching(launchedByBluetoothRestoration: Bool) {
        guard let live else { return }
        live.launchedByBluetoothRestoration = launchedByBluetoothRestoration
        Task { await live.bootstrap() }
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        guard let live else { return }
        switch phase {
        case .active:
            Task { await live.handleForeground() }
        case .background:
            live.handleBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func handleNotificationResponse(actionIdentifier: String, userInfo: [String: String]) async {
        await live?.handleNotificationResponse(actionIdentifier: actionIdentifier, userInfo: userInfo)
    }
}
