// Holds the view states the screens render and receives their actions (docs/app-wiring.md).
//
// `launch(services:)` builds every view state from `AppServices`, then follows
// `services.changes()`: each `ServiceChange` rebuilds only the view states that read the
// properties it names (`apply(_:)`). A UI clock tick (RootView: every 15 s, and on foreground)
// re-evaluates the clock-mismatch latch through the facade and reloads "Today so far" at midnight;
// the screens classify staleness against the clock themselves (S5). Chart points, "Today so far"
// and Trends statistics are computed off the main actor. Actions (AppModel+Actions.swift) call the
// facade; the view states follow from the `ServiceChange`s it sends back.
//
// Nothing here creates a reading (S1). The current value is only ever the facade's latest *live*
// reading (S6), and a reading dated ahead of the clock is never current (S1/S5).

import AlertEngine
import Foundation
import GlucoseCore
import Observation
import UIKit
import WidgetCore

@MainActor
@Observable
final class AppModel {
    var selectedTab: AppTab = .now
    var now: NowViewState
    var trends: TrendsViewState
    var alerts: AlertsViewState
    var settings: SettingsViewState
    var calibration: CalibrationViewState
    /// Non-nil while onboarding is shown.
    var onboarding: OnboardingState?
    var isCalibrationPresented = false
    /// Settings › Import history while presented (the onboarding import step, on its own).
    var importSheet: OnboardingState?
    /// Settings sub-page to open (from a banner or the Now menu).
    var settingsRoute: SettingsRoute?
    /// G7Kit `hasStoredSensor` (review N2): whether `pairAgain(code:)` has a sensor to re-pair.
    var hasStoredSensor = false
    /// Whether a sensor was stored when the onboarding pairing started (review N1 item 3: the sensor
    /// authenticated in this pairing once `hasStoredSensor` becomes true after that). Nil when the
    /// pairing started before the stored sensor was known (`AppServices.storedSensorKnown`): then
    /// nothing counts as authenticated in this pairing.
    @ObservationIgnored var hadStoredSensorAtPairingStart: Bool?
    /// A file to hand to the share sheet (CSV export, diagnostics).
    var sharedFile: SharedFile?

    /// Nil only for the DEBUG fixture model (`fixtures()`: previews and fixture-based tests).
    let services: (any AppServices)?
    /// The clock the UI classifies against (staleness, the latch, "today"): the phone clock, or in a
    /// DEBUG replay run the replay clock (`AppServices.replayClockNow`), so an accelerated replay's
    /// readings are current rather than "dated ahead of the phone clock".
    let clock: @MainActor () -> Date
    let preferences: AppUIPreferences?
    /// Whether the phone's protected data is readable (false before the first unlock after a restart,
    /// e.g. a Bluetooth-restoration launch). UI preferences are read and written, and onboarding is
    /// decided, only once it is (review m2). Injected in tests.
    let protectedDataAvailable: @MainActor () -> Bool
    @ObservationIgnored var calendar: Calendar = .current

    @ObservationIgnored private var observation: Task<Void, Never>?
    /// Async work started by the model (reloads, actions) and not finished yet. Tests await it with
    /// `settle()`.
    @ObservationIgnored private var pendingWork: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var recentGeneration = 0
    @ObservationIgnored private var trendsGeneration = 0
    @ObservationIgnored private var trendsStale = true
    /// Statistics have been shown for the selected period (a recompute keeps them until the new ones
    /// are ready; the first computation shows progress instead of "no readings").
    @ObservationIgnored private(set) var trendsComputed = false
    /// The model's own memoryless clock-mismatch check (defence in depth next to the facade's).
    @ObservationIgnored private var localClockLatch: Date?
    /// Local midnight of the day "Today so far" was last computed for.
    @ObservationIgnored private var todayComputedFor: Date?
    /// When the current `.failed` sensor state began, and its kind.
    @ObservationIgnored private var failure: (kind: SensorFailure.Kind, since: Date)?
    /// A code was submitted and the sensor has not answered yet.
    @ObservationIgnored var pairingInProgress = false
    /// Review m3: a connection step (searching/connecting/authenticating) has been seen since the
    /// onboarding code was submitted, so the sensor state now describes this pairing rather than
    /// the previous sensor.
    @ObservationIgnored var pairingSawConnectionStep = false
    /// The last `hasStoredSensor` read was the source's, not the facade's launch default
    /// (`AppServices.storedSensorKnown`; review m3 hardening: bootstrap's first stored-sensor report
    /// is not a connection).
    @ObservationIgnored private var storedSensorReadWasKnown = false
    /// Review M1: the facade's sensor state is real. Before the source's first state reaches the
    /// facade it reports `.notPaired` by default; until a `.sensor` change arrives (or the state is
    /// anything but `.notPaired`, or a sensor is stored) nothing offers to pair.
    @ObservationIgnored private(set) var sensorStateKnown = false
    /// Review m2: UI preferences have been read (protected data was available).
    @ObservationIgnored private(set) var preferencesLoaded = false
    /// Whether to show onboarding has been decided (once per launch).
    @ObservationIgnored private var onboardingDecided = false
    @ObservationIgnored private var launchArguments: [String] = []
    @ObservationIgnored private var protectedDataObserver: NSObjectProtocol?
    /// Time zone and clock changes (`NSSystemTimeZoneDidChange`, `significantTimeChangeNotification`).
    @ObservationIgnored private var timeObservers: [NSObjectProtocol] = []
    /// Alert settings sent to the facade and not yet confirmed by a `.alertSettings` change; the next
    /// edit builds on them (AppModel+Actions `editAlert`).
    @ObservationIgnored var alertSettingsDraft: AlertSettings?
    /// The last `updateAlertSettings` call in flight: each waits for the one before, so the engine
    /// ends up with the last edit whatever order the calls would otherwise finish in.
    @ObservationIgnored var alertUpdate: Task<Void, Never>?
    /// Fixture model only (`fixtures()`, no services): alert edits apply here.
    @ObservationIgnored var fixtureAlertSettings = AlertSettings.defaults

    /// Onboarding's pairing context (review N1/N2): a new pairing, which counts as authenticated
    /// once a sensor is stored that wasn't when this pairing started.
    var onboardingPairingContext: PairingContext {
        let authenticated = hadStoredSensorAtPairingStart == false && hasStoredSensor
        return PairingContext(hasStoredSensor: hasStoredSensor, isNewPairing: true, authenticatedInThisPairing: authenticated)
    }

    init(now: NowViewState, trends: TrendsViewState, alerts: AlertsViewState, settings: SettingsViewState, calibration: CalibrationViewState, onboarding: OnboardingState?) {
        self.now = now
        self.trends = trends
        self.alerts = alerts
        self.settings = settings
        self.calibration = calibration
        self.onboarding = onboarding
        self.services = nil
        self.clock = { Date() }
        self.preferences = nil
        self.protectedDataAvailable = { true }
        self.sensorStateKnown = true
    }

    private init(services: any AppServices, preferences: AppUIPreferences, clock: @escaping @MainActor () -> Date,
                 protectedDataAvailable: @escaping @MainActor () -> Bool) {
        self.services = services
        self.preferences = preferences
        self.clock = clock
        self.protectedDataAvailable = protectedDataAvailable
        // No preference is read here (review m2): `loadPreferences()` does, once protected data is
        // available.
        now = .empty
        trends = .empty(period: .default)
        alerts = AlertsMapping.make(.defaults)
        settings = Self.emptySettings(appearance: .default)
        calibration = .unavailable
        onboarding = nil
    }

    var accent: AccentChoice { settings.accent }

    // MARK: - Launch

    /// The running app: every view state from `services`, then kept up to date from
    /// `services.changes()`.
    ///
    /// Onboarding is decided once both the sensor state is known and protected data is available
    /// (`decideOnboardingIfReady`), never from the facade's launch defaults.
    ///
    /// Launch arguments: `-onboarding` shows onboarding; `-tab <now|trends|alerts|settings>` opens a
    /// tab; DEBUG `-resetOnboardingFlag` forgets that onboarding was completed (UI tests). A replay
    /// run (DEBUG `-replayScenario`, started by the services) never shows onboarding.
    static func launch(
        services: any AppServices,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        preferences: AppUIPreferences = AppUIPreferences(),
        calendar: Calendar = .current,
        clock: (@MainActor () -> Date)? = nil,
        protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    ) -> AppModel {
        let model = AppModel(services: services, preferences: preferences, clock: clock ?? defaultClock(services),
                             protectedDataAvailable: protectedDataAvailable)
        model.calendar = calendar
        model.launchArguments = arguments
        // `.notPaired` is also the facade's default before the source's first state: not evidence.
        model.sensorStateKnown = services.sensorState != .notPaired || services.hasStoredSensor
        model.rebuildAll()
        model.loadPreferences()
        if !model.preferencesLoaded { model.waitForProtectedData() }
        if let index = arguments.firstIndex(of: "-tab"), index + 1 < arguments.count, let tab = AppTab(rawValue: arguments[index + 1]) {
            model.selectedTab = tab
        }
        model.startObserving()
        return model
    }

    /// The phone clock; in a DEBUG replay run, the replay clock (compiled out of Release).
    static func defaultClock(_ services: any AppServices) -> @MainActor () -> Date {
        #if DEBUG
        return { [weak services] in services?.replayClockNow ?? Date() }
        #else
        return { Date() }
        #endif
    }

    // MARK: - Preferences and the onboarding decision (review M1, m2)

    /// Reads the UI preferences once protected data is available, merges what the services reported
    /// meanwhile, and decides onboarding if the sensor state is known.
    func loadPreferences() {
        guard !preferencesLoaded, let preferences, protectedDataAvailable() else { return }
        preferencesLoaded = true
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
            self.protectedDataObserver = nil
        }
        #if DEBUG
        if launchArguments.contains("-resetOnboardingFlag") { preferences.onboardingCompleted = false }
        if launchArguments.contains("-resetConnectionMode") { preferences.connectionModeChosen = false }
        #endif
        refreshConnection()
        settings.appearance = preferences.appearance
        // Phase 3: the tab and Trends period from before the app was killed (an explicit `-tab`
        // launch argument wins).
        if let period = preferences.trendsPeriod, period != trends.period, !trendsComputed {
            trends = .empty(period: period)
            trendsStale = true
        }
        if !launchArguments.contains("-tab"), let tab = preferences.selectedTab {
            selectTab(tab)
        }
        // The stored need, or one seen since launch, kept or cleared by the state now (review minor 4).
        let needsCalibration = CalibrationNeed.update(previous: preferences.sensorNeedsCalibration || now.sensorNeedsCalibration,
                                                      sensorState: now.sensorState)
        now.sensorNeedsCalibration = needsCalibration
        preferences.sensorNeedsCalibration = needsCalibration
        if sensorStateKnown, OnboardingMapping.sensorIsSetUp(sensorState: now.sensorState, hasStoredSensor: hasStoredSensor) {
            preferences.onboardingCompleted = true
        }
        decideOnboardingIfReady()
    }

    /// Also retried on every change and clock tick (`apply`, `tick`).
    private func waitForProtectedData() {
        protectedDataObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.loadPreferences() }
        }
    }

    /// Shows onboarding at launch if it is due — once, and only when the sensor state is real and
    /// the preferences could be read.
    private func decideOnboardingIfReady() {
        guard !onboardingDecided, sensorStateKnown, preferencesLoaded, let services, let preferences else { return }
        onboardingDecided = true
        if OnboardingMapping.showsAtLaunch(sensorState: services.sensorState, hasStoredSensor: services.hasStoredSensor,
                                           onboardingCompleted: preferences.onboardingCompleted,
                                           replayActive: services.replay.activeScenario != nil, arguments: launchArguments) {
            presentOnboarding(at: .welcome)
        }
    }

    #if DEBUG
    /// DEBUG: fixture view states and no services, for previews and the fixture-based unit tests
    /// (`-nowScenario <name>`, `-tab <tab>`, `-onboarding`). The app launches with
    /// `launch(services:)`.
    static func fixtures(arguments: [String] = []) -> AppModel {
        var scenario = Fixtures.NowScenario.normal
        if let index = arguments.firstIndex(of: "-nowScenario"), index + 1 < arguments.count,
           let chosen = Fixtures.NowScenario(rawValue: arguments[index + 1]) {
            scenario = chosen
        }
        let current = Date()
        let model = AppModel(
            now: Fixtures.now(scenario, at: current),
            trends: Fixtures.trends(.default, at: current),
            alerts: Fixtures.alerts,
            settings: Fixtures.settings(at: current),
            calibration: Fixtures.calibration(.available, at: current),
            onboarding: arguments.contains("-onboarding") ? .initial : nil
        )
        if let index = arguments.firstIndex(of: "-tab"), index + 1 < arguments.count,
           let tab = AppTab(rawValue: arguments[index + 1]) {
            model.selectedTab = tab
        }
        return model
    }
    #endif

    static func emptySettings(appearance: AppearancePreference) -> SettingsViewState {
        SettingsViewState(
            sensor: SensorSettings(state: .notPaired, serial: nil),
            trio: TrioSettings(isEnabled: false, status: .off),
            nightscout: NightscoutSettings(url: "", hasToken: false, uploadEnabled: false, status: .off),
            dexcomShare: DexcomShareSettings(isEnabled: false, username: "", hasPassword: false, region: .default, status: .off),
            delivery: AlertDeliveryStatus(notifications: .notDetermined, urgentLowAlarm: .defaultForThisOS, criticalAlerts: .entitlementNotGranted, alarmVolume: .unknown),
            lastImport: nil,
            accent: .default,
            appearance: appearance,
            unit: .mgdL,
            retention: .default,
            databaseSizeBytes: nil,
            appVersion: AppIdentity.version
        )
    }

    // MARK: - Following the services

    private func startObserving() {
        guard let services, observation == nil else { return }
        // Phase 3: a time zone change moves local midnight (Now's "today", Trends' days, AGP time of
        // day); a significant time change (midnight, DST, a manual clock change) re-checks the latch
        // and "today". Labels use `DisplayContext.current` (autoupdating) and follow on the next render.
        for name in [Notification.Name.NSSystemTimeZoneDidChange, UIApplication.significantTimeChangeNotification] {
            timeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let timeZoneChanged = notification.name == .NSSystemTimeZoneDidChange
                Task { @MainActor in
                    guard let self else { return }
                    if timeZoneChanged {
                        NSTimeZone.resetSystemTimeZone()
                        self.calendarDidChange(.current)
                    } else {
                        self.tick()
                    }
                }
            })
        }
        let changes = services.changes()
        observation = Task { [weak self] in
            for await change in changes {
                guard let self else { return }
                self.apply(change)
            }
        }
    }

    /// Every view state from the services' current values.
    func rebuildAll() {
        for change in ServiceChange.allCases { rebuild(change) }
    }

    /// A change the services sent. A `.sensor` change means the sensor state is the source's, not
    /// the facade's launch default (review M1).
    func apply(_ change: ServiceChange) {
        if change == .sensor, !sensorStateKnown {
            sensorStateKnown = true
        }
        rebuild(change)
        if !preferencesLoaded { loadPreferences() } // decides onboarding too
        if change == .sensor { decideOnboardingIfReady() }
    }

    /// Rebuilds the view states that read what `change` names (ServiceValues.swift), nothing else.
    private func rebuild(_ change: ServiceChange) {
        guard let services else { return }
        let time = clock()
        switch change {
        case .readings:
            refreshLatestReading(time)
            reloadRecentReadings()
            trendsStale = true
            if selectedTab == .trends { refreshTrends() }
        case .sensor:
            refreshSensor(time)
        case .calibration:
            calibration.lastSubmission = CalibrationMapping.lastSubmission(services.recentCalibrations)
            now.fingersticks = NowMapping.fingersticks(services.recentCalibrations, now: time)
        case .trio:
            settings.trio = SettingsMapping.trio(services.trio, now: time)
            refreshHealth(time)
        case .uploads:
            settings.nightscout = SettingsMapping.nightscout(services.nightscout, now: time)
            settings.dexcomShare = SettingsMapping.dexcomShare(services.dexcomShare, now: time)
            updateImportForms {
                $0.nightscoutSiteURL = services.nightscout.siteURL
                $0.nightscoutHasToken = services.nightscout.hasToken
            }
            refreshHealth(time)
        case .historyImport:
            let progress = OnboardingMapping.importProgress(services.historyImport)
            updateImportForms { $0.importProgress = progress }
            settings.runningImport = progress?.isRunning == true ? progress : nil
            if let last = SettingsMapping.lastImport(services.historyImport) { settings.lastImport = last }
        case .alertSettings:
            // While an edit is on its way, the draft is what the person just set; the facade's value
            // replaces it once it matches (or the edit's own update finishes).
            if let draft = alertSettingsDraft, draft != services.alertSettings { break }
            alertSettingsDraft = nil
            alerts = AlertsMapping.make(services.alertSettings)
        case .alertDelivery:
            settings.delivery = SettingsMapping.delivery(services.alertDelivery)
            refreshOnboardingPermissions()
            refreshHealth(time)
        case .storage:
            let storage = services.storage
            settings.retention = storage.retention
            settings.databaseSizeBytes = storage.summary?.fileSizeBytes
            settings.readingCount = storage.summary?.readingCount
            settings.storageAvailability = storage.availability
            refreshHealth(time)
        case .health:
            refreshLatestReading(time) // the latch
            settings.sensor.bluetooth = services.bluetoothAuthorization
            refreshOnboardingPermissions()
            refreshHealth(time)
        case .appearance:
            settings.accent = services.accent
        case .replay:
            refreshReplay()
        }
    }

    /// A new calendar (the time zone changed): local midnight moves, so "Today so far", the Now
    /// chart's data and Trends' periods, AGP buckets and day traces are recomputed in it.
    func calendarDidChange(_ newCalendar: Calendar) {
        guard newCalendar != calendar else { return }
        calendar = newCalendar
        reloadRecentReadings()
        trendsStale = true
        if selectedTab == .trends { refreshTrends() }
        tick()
    }

    /// The UI clock (RootView: every 15 s and when the app comes to the foreground).
    func tick() {
        guard let services else { return }
        // `isProtectedDataAvailable` can read false while the SwiftUI app is still being created,
        // before UIKit has finished launching; the first tick (first render) tries again.
        if !preferencesLoaded { loadPreferences() }
        let time = clock()
        services.updateClockMismatchLatch(now: time)
        refreshLatch(time)
        if let computedFor = todayComputedFor, computedFor != calendar.startOfDay(for: time) {
            reloadRecentReadings() // midnight: "Today so far" starts over
        }
    }

    // MARK: Now

    private func refreshLatestReading(_ time: Date) {
        guard let services else { return }
        let latest = NowMapping.latestLiveReading(services.latestLiveReading, previous: services.previousLiveReading)
        if now.latestLiveReading != latest { now.latestLiveReading = latest }
        if calibration.latestLiveReading != latest { calibration.latestLiveReading = latest }
        refreshLatch(time)
    }

    /// Mirrors the facade's persisted latch into Now and Calibration, together with the model's own
    /// memoryless check: a reading seen dated ahead of the clock stays "not current" until a newer
    /// one replaces it, whichever of the two noticed (S1/S5).
    private func refreshLatch(_ time: Date) {
        localClockLatch = ClockMismatchLatch.update(latchedFor: localClockLatch, latest: now.latestLiveReading, now: time)
        let latched = NowMapping.clockMismatchLatch(facade: services?.clockMismatchLatchedFor, local: localClockLatch,
                                                    latestDate: now.latestLiveReading?.date)
        if now.clockMismatchLatchedFor != latched { now.clockMismatchLatchedFor = latched }
        if calibration.clockMismatchLatchedFor != latched { calibration.clockMismatchLatchedFor = latched }
    }

    /// Chart points (24 h) and "Today so far", read from the store and computed off the main actor.
    /// Only the newest request's result is applied.
    func reloadRecentReadings() {
        guard let services else { return }
        recentGeneration += 1
        let generation = recentGeneration
        let time = clock()
        let calendar = self.calendar
        let interval = NowMapping.fetchInterval(now: time, calendar: calendar)
        track { [weak self] in
            guard let readings = try? await services.readings(from: interval.start, to: interval.end) else {
                return // store not open: the storage banner says so; keep what is shown
            }
            let recent = await Task.detached(priority: .userInitiated) {
                NowMapping.recent(readings, now: time, calendar: calendar)
            }.value
            guard let self, generation == self.recentGeneration else { return }
            self.now.chartPoints = recent.chartPoints
            self.now.today = recent.today
            self.todayComputedFor = calendar.startOfDay(for: time)
        }
    }

    // MARK: Sensor

    private func refreshSensor(_ time: Date) {
        guard let services else { return }
        let state = services.sensorState
        let wasStored = hasStoredSensor
        let baselineKnown = storedSensorReadWasKnown
        hasStoredSensor = services.hasStoredSensor
        storedSensorReadWasKnown = services.storedSensorKnown
        if hasStoredSensor { sensorStateKnown = true }
        // Review m3 hardening: a sensor that became stored while a pairing was on its way is proof
        // the sensor answered this pairing, even if no connection step was reported. Only a change
        // from a known "not stored" counts (`storedSensorKnown`): a sensor stored before the pairing
        // never flips, and bootstrap's first read of the stored record replaces a default.
        if pairingInProgress, baselineKnown, !wasStored, hasStoredSensor { pairingSawConnectionStep = true }
        now.sensorStateKnown = sensorStateKnown
        now.sensorState = state
        now.sensorSession = services.sensorSession
        calibration.sensorState = state
        calibration.acceptedRange = services.acceptedCalibrationRange

        // Review minor 4: remember a calibration request through transient failures (persisted).
        let needsCalibration = CalibrationNeed.update(previous: now.sensorNeedsCalibration, sensorState: state)
        if needsCalibration != now.sensorNeedsCalibration {
            now.sensorNeedsCalibration = needsCalibration
            if preferencesLoaded { preferences?.sensorNeedsCalibration = needsCalibration }
        }

        // When the current failure began (PairingGuidance.credentialsRetryWindow).
        if case .failed(let current) = state {
            if failure?.kind != current.kind { failure = (current.kind, time) }
        } else {
            failure = nil
        }

        // A pairing is answered once the sensor reports anything past the connection steps that
        // follow the code (review m3: not the previous sensor's state).
        switch state {
        case .searching, .connecting, .authenticating:
            pairingSawConnectionStep = true
        case .bluetoothUnavailable, .notPaired:
            break
        case .warmingUp, .active, .gracePeriod, .expired, .failed, .error, .calibrationNeeded, .calibrationError:
            if pairingSawConnectionStep { pairingInProgress = false }
        }
        let sensorIsSetUp = sensorStateKnown && OnboardingMapping.sensorIsSetUp(sensorState: state, hasStoredSensor: hasStoredSensor)
        if sensorIsSetUp, preferencesLoaded { preferences?.onboardingCompleted = true }

        settings.sensor = SettingsMapping.sensor(state: state, session: services.sensorSession, storedSerial: services.storedSensorSerial,
                                                 canStopSession: services.canStopSession,
                                                 bluetooth: services.bluetoothAuthorization, failureSince: failure?.since,
                                                 pairingInProgress: pairingInProgress)
        settings.sensor.stateKnown = sensorStateKnown

        refreshConnection()

        if var onboarding {
            onboarding.sensorState = state
            onboarding.currentConnectionMode = services.connectionMode
            onboarding.connectionSwitchNeedsConfirmation = hasStoredSensor
            onboarding.pairing = OnboardingMapping.pairing(current: onboarding.pairing, sensorState: state,
                                                           sawConnectionStep: pairingSawConnectionStep)
            // An existing sensor showed up before the person started onboarding (e.g. after an
            // update): nothing to set up — unless onboarding was asked for (`-onboarding`).
            if onboarding.step == .welcome, sensorIsSetUp, !launchArguments.contains("-onboarding") {
                self.onboarding = nil
            } else {
                self.onboarding = onboarding
            }
        }
    }

    // MARK: Connection mode (D45) and packet recording (D47)

    /// The facade's mode on Now and in calibration; in Settings only once the person has chosen
    /// (`AppUIPreferences.connectionModeChosen`): a new install's stored `.pair` is a storage default,
    /// never shown as the choice. Listening, or a sensor stored in pairing mode (an install from
    /// before D45), counts as chosen.
    func refreshConnection() {
        guard let services else { return }
        let mode = services.connectionMode
        if preferencesLoaded, let preferences, !preferences.connectionModeChosen, mode == .listen || hasStoredSensor {
            preferences.connectionModeChosen = true
        }
        // Review m2/m3: an untrusted setting is no choice: Settings asks again.
        let chosen = preferencesLoaded && preferences?.connectionModeChosen == true && services.connectionSettingProblem == nil
        now.connection = ConnectionModeState(mode: mode)
        now.connectionChosen = chosen
        settings.connection = ConnectionModeState(mode: chosen ? mode : nil)
        settings.packetRecording = PacketRecordingState(isOn: services.recordsRawGlucosePackets)
        calibration.listening = mode == .listen
    }

    /// Remembers that the person chose (onboarding's Continue, Settings' confirmation).
    func noteConnectionModeChosen() {
        if preferencesLoaded { preferences?.connectionModeChosen = true }
        refreshConnection()
    }

    // MARK: Health (S5)

    private func refreshHealth(_ time: Date) {
        guard let services else { return }
        var health = ServiceHealthMapping.make(
            trio: services.trio, nightscout: services.nightscout, dexcomShare: services.dexcomShare,
            delivery: services.alertDelivery, forceQuitGap: services.forceQuitGap, storage: services.storage,
            bluetooth: services.bluetoothAuthorization, now: time
        )
        health.connectionSettingProblem = services.connectionSettingProblem
        // Keep the "since" of a problem that is already showing, so the banner doesn't move.
        if case .failing(_, let message) = health.trio, case .failing(let since, let shownMessage) = now.health.trio, message == shownMessage {
            health.trio = .failing(since: since, message: message)
        }
        if now.health != health { now.health = health }
    }

    // MARK: Onboarding

    func presentOnboarding(at step: OnboardingStep) {
        var state = freshOnboardingState(at: step)
        if let services {
            // D45: the connection step. D7's "Share upload on" is for pairing mode only (the Dexcom
            // app keeps sharing while this app listens).
            // Nothing preselected, ever: the person chooses before any pairing step (no accidental
            // takeover of the Dexcom app's connection).
            let mode = services.connectionMode
            state.connection = ConnectionModeState(mode: nil)
            state.currentConnectionMode = mode
            state.connectionSwitchNeedsConfirmation = services.hasStoredSensor
            state.shareUploadEnabled = mode == .pair
        }
        onboarding = state
        hadStoredSensorAtPairingStart = nil
        refreshOnboardingPermissions()
    }

    /// Settings › Import history.
    func presentImport() {
        importSheet = freshOnboardingState(at: .importHistory)
    }

    private func freshOnboardingState(at step: OnboardingStep) -> OnboardingState {
        var state = OnboardingState.initial
        state.step = step
        if let services {
            state.sensorState = services.sensorState
            state.nightscoutSiteURL = services.nightscout.siteURL
            state.nightscoutHasToken = services.nightscout.hasToken
            state.importProgress = OnboardingMapping.importProgress(services.historyImport)
            state.shareRegion = services.dexcomShare.region
        }
        return state
    }

    /// The import form is in onboarding and in Settings › Import history: keep both current.
    func updateImportForms(_ change: (inout OnboardingState) -> Void) {
        if onboarding != nil { change(&onboarding!) }
        if importSheet != nil { change(&importSheet!) }
    }

    private func refreshOnboardingPermissions() {
        guard let services, onboarding != nil else { return }
        let delivery = SettingsMapping.delivery(services.alertDelivery)
        onboarding?.bluetooth = OnboardingMapping.bluetooth(services.bluetoothAuthorization)
        onboarding?.notifications = delivery.notifications
        onboarding?.criticalAlerts = delivery.criticalAlerts
        onboarding?.urgentLowAlarm = delivery.urgentLowAlarm
    }

    // MARK: DEBUG replay

    private func refreshReplay() {
        guard let services else { return }
        now.replayScenario = services.replay.activeScenario
        #if DEBUG
        settings.debug = SettingsMapping.debug(services.replay)
        // A replay run provides the sensor: close an onboarding nobody has started.
        if services.replay.activeScenario != nil, onboarding?.step == .welcome { onboarding = nil }
        #endif
    }

    // MARK: Trends

    func selectTrendsPeriod(_ period: TrendsPeriod) {
        guard services != nil else {
            #if DEBUG
            trends = Fixtures.trends(period, at: Date())
            #else
            trends = .empty(period: period)
            #endif
            return
        }
        guard period != trends.period || trends.loadError != nil else { return }
        if preferencesLoaded { preferences?.trendsPeriod = period }
        trends = .empty(period: period)
        trendsComputed = false
        refreshTrends()
    }

    func selectTab(_ tab: AppTab) {
        selectedTab = tab
        if preferencesLoaded { preferences?.selectedTab = tab }
        if tab == .trends, trendsStale { refreshTrends() }
    }

    /// Statistics for the selected period, from the store, computed off the main actor. The
    /// numbers shown stay until the new ones are ready (same period); only the newest request's
    /// result is applied.
    func refreshTrends() {
        guard let services else { return }
        trendsStale = false
        trendsGeneration += 1
        let generation = trendsGeneration
        let period = trends.period
        let time = clock()
        let calendar = self.calendar
        let interval = TrendsMapping.fetchInterval(period: period, now: time, calendar: calendar)
        if !trendsComputed { trends.isComputing = true }
        track { [weak self] in
            let result: TrendsViewState
            do {
                let readings = try await services.readings(from: interval.start, to: interval.end)
                result = await Task.detached(priority: .userInitiated) {
                    TrendsMapping.make(period: period, readings: readings, now: time, calendar: calendar)
                }.value
            } catch {
                var failed = TrendsViewState.empty(period: period)
                failed.loadError = "Statistics aren't available yet: the reading database isn't open."
                result = failed
            }
            guard let self, generation == self.trendsGeneration else { return }
            self.trends = result
            self.trendsComputed = result.loadError == nil
        }
    }

    // MARK: Async work

    /// Runs `work` on the main actor and remembers it until it finishes, so tests can wait for it
    /// (`settle()`).
    @discardableResult
    func track(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        // Registered before the task can run: it runs on the main actor after this returns.
        let task = Task { @MainActor [weak self] in
            await work()
            self?.pendingWork[id] = nil
        }
        pendingWork[id] = task
        return task
    }

    /// Waits for every piece of async work the model started, including work started meanwhile.
    func settle() async {
        while let task = pendingWork.values.first {
            await task.value
        }
    }
}

enum SettingsRoute: Hashable, Sendable {
    case sensor
    case trio
    case sharing
    case alertDelivery
    case about
    #if DEBUG
    case developer
    #endif
}

/// A file for the share sheet.
struct SharedFile: Identifiable, Equatable, Sendable {
    let url: URL
    var id: URL { url }
}
