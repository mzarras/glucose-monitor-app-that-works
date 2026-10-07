// `AppServices` values → view states. Pure (no clock of their own, no I/O), so every rule here is
// unit-tested with plain values (AppModelMappingTests). `AppModel` calls these after each
// `ServiceChange` and on its clock tick.

import AlertEngine
import Foundation
import GlucoseCore
import GlucoseStats
import GlucoseStore
import NightscoutKit
import WidgetCore

// MARK: - Now

enum NowMapping {
    /// Whether a reading may be the current value (S6): live sensor readings only — in a DEBUG
    /// replay run also replay/mock readings (D11, D20). Imported history never.
    static func isLive(_ source: ReadingSource) -> Bool {
        switch source {
        case .sensor:
            return true
        case .imported:
            return false
        case .replay, .mock:
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
    }

    /// The hero's reading: the facade's latest live reading with the delta to the previous one.
    /// Defence in depth for S6: anything that is not live is refused here too, and a previous
    /// reading that is not live gives no delta.
    static func latestLiveReading(_ latest: GlucoseReading?, previous: GlucoseReading?) -> LatestReading? {
        guard let latest, isLive(latest.source) else { return nil }
        return LatestReading(reading: latest, previous: previous.flatMap { isLive($0.source) ? $0 : nil })
    }

    /// What the Now screen reads from the store: 24 h of chart before `now`, and "today so far" with
    /// 24 h of hypo context before midnight (docs/statistics.md), whichever starts earlier. The end
    /// allows a reading within the gate's future tolerance.
    static func fetchInterval(now: Date, calendar: Calendar) -> DateInterval {
        let chartStart = now.addingTimeInterval(-TimeInterval(ChartWindow.twentyFourHours.duration))
        let contextStart = calendar.startOfDay(for: now).addingTimeInterval(-PeriodReadings.contextDuration)
        let start = min(chartStart, contextStart)
        return DateInterval(start: start, end: now.addingTimeInterval(LiveReadingGate.futureTolerance))
    }

    struct Recent: Equatable, Sendable {
        var chartPoints: [ChartPoint]
        var today: TodaySummary
    }

    /// Chart points (last 24 h, any source — imported history may be charted, S6) and "Today so
    /// far" from GlucoseStats. Nothing is added or smoothed (S1).
    static func recent(_ readings: [GlucoseReading], now: Date, calendar: Calendar) -> Recent {
        let chartStart = now.addingTimeInterval(-ChartWindow.twentyFourHours.duration)
        let chart = readings
            .filter { $0.date >= chartStart }
            .sorted { $0.date < $1.date }
            .map(ChartPoint.init)
        return Recent(chartPoints: chart, today: today(readings, now: now, calendar: calendar))
    }

    /// HANDOFF §7.3.1 "Today so far": time in range, average, lows (level 1 events overlapping
    /// today, `level1EventCountOverlappingPeriod`). No readings today → every figure "—".
    static func today(_ readings: [GlucoseReading], now: Date, calendar: Calendar) -> TodaySummary {
        let stats = GlucoseStatistics.todaySoFar(readings: readings, now: now, options: StatisticsOptions(calendar: calendar))
        guard stats.readingCount > 0 else { return TodaySummary(timeInRangePercent: nil, averageMgdl: nil, lowCount: nil) }
        return TodaySummary(
            timeInRangePercent: stats.ranges.inRange.percent.map { Int($0.rounded()) },
            averageMgdl: stats.meanAndVariability.meanMgdl.map { Int($0.rounded()) },
            lowCount: stats.level1EventCountOverlappingPeriod
        )
    }

    /// What the Now chart draws and scrubs at `now`: the stored points up to `now`, none dated after
    /// it (Phase 3: after the phone's clock was set back, a stored reading can be dated in the
    /// future; it is not drawn or selectable until the clock passes it, and the hero says "clock
    /// doesn't match" meanwhile).
    static func visibleChartPoints(_ points: [ChartPoint], now: Date) -> [ChartPoint] {
        guard let last = points.last, last.date > now else { return points } // ascending: the common case is free
        return points.filter { $0.date <= now }
    }

    /// Fingerstick calibrations to mark on the chart (last 24 h). Markers, never readings (S1).
    static func fingersticks(_ records: [CalibrationRecord], now: Date) -> [FingerstickMarker] {
        let start = now.addingTimeInterval(-ChartWindow.twentyFourHours.duration)
        return records
            .filter { $0.request.takenAt >= start && $0.request.takenAt <= now.addingTimeInterval(LiveReadingGate.futureTolerance) }
            .sorted { $0.request.takenAt < $1.request.takenAt }
            .map { FingerstickMarker(date: $0.request.takenAt, mgdl: $0.request.mgdl) }
    }

    /// The latch to show: whichever of the facade's (persisted) latch and the model's own memoryless
    /// check holds for the latest reading (S1/S5: errs toward "not current").
    static func clockMismatchLatch(facade: Date?, local: Date?, latestDate: Date?) -> Date? {
        if let latestDate, facade == latestDate || local == latestDate { return latestDate }
        return facade ?? local
    }
}

// MARK: - Calibration (PROGRESS D16)

enum CalibrationMapping {
    /// The most recent submission and what happened to it (records are newest first).
    static func lastSubmission(_ records: [CalibrationRecord]) -> CalibrationSubmission? {
        guard let record = records.first else { return nil }
        let outcome: CalibrationSubmission.Outcome
        if let refusal = record.refusal {
            outcome = .refused(refusal.refusal)
        } else if let status = record.status {
            outcome = .status(status)
        } else {
            // Neither refused nor reported: say so rather than claim it was queued.
            outcome = .status(.unknown(description: "No status from the sensor yet"))
        }
        return CalibrationSubmission(request: record.request, outcome: outcome, updatedAt: record.updatedAt)
    }
}

// MARK: - Settings

enum SettingsMapping {
    static func sensor(state: SensorState, session: SensorSession?, storedSerial: String?, canStopSession: Bool, bluetooth: BluetoothAuthorization,
                       failureSince: Date?, pairingInProgress: Bool) -> SensorSettings {
        SensorSettings(state: state, serial: session?.serial ?? storedSerial, failureSince: failureSince, canStopSession: canStopSession,
                       session: session, bluetooth: bluetooth, pairingInProgress: pairingInProgress)
    }

    static func trio(_ trio: TrioBridgeSummary, now: Date) -> TrioSettings {
        TrioSettings(
            isEnabled: trio.isEnabled,
            status: ServiceHealthMapping.trioStatus(trio, now: now),
            appGroupID: trio.appGroupID,
            lastWriteAt: trio.lastSuccessfulWriteAt,
            readingsInLastWrite: trio.readingsInLastWrite,
            newestReadingWrittenAt: trio.newestReadingWrittenAt,
            heartbeatPublished: trio.heartbeatPublished,
            heartbeatError: trio.heartbeatError,
            pausedInDebugBuild: trio.isEnabled && !trio.liveOutputsAllowed,
            unavailableReason: trio.isEnabled ? trio.unavailableReason : nil,
            heldBackReadings: trio.heldBackReadings,
            heldBackSince: trio.heldBackSince
        )
    }

    static func nightscout(_ nightscout: NightscoutSummary, now: Date) -> NightscoutSettings {
        NightscoutSettings(
            url: nightscout.siteURL ?? "",
            hasToken: nightscout.hasToken,
            uploadEnabled: nightscout.upload.isEnabled,
            status: ServiceHealthMapping.uploadStatus(nightscout.upload, notSetUp: ServiceHealthMapping.nightscoutNotSetUp(nightscout), now: now),
            queueDepth: nightscout.upload.status?.queueDepth ?? 0,
            pausedInDebugBuild: nightscout.upload.isEnabled && !nightscout.upload.liveOutputsAllowed
        )
    }

    static func dexcomShare(_ share: DexcomShareSummary, now: Date) -> DexcomShareSettings {
        DexcomShareSettings(
            isEnabled: share.upload.isEnabled,
            username: share.accountName ?? "",
            hasPassword: share.hasPassword,
            region: share.region,
            status: ServiceHealthMapping.uploadStatus(share.upload, notSetUp: ServiceHealthMapping.shareNotSetUp(share), now: now),
            receiverSerialNumber: share.receiverSerialNumber ?? "",
            queueDepth: share.upload.status?.queueDepth ?? 0,
            pausedInDebugBuild: share.upload.isEnabled && !share.upload.liveOutputsAllowed
        )
    }

    static func delivery(_ report: AlertDeliveryReport) -> AlertDeliveryStatus {
        AlertDeliveryStatus(
            notifications: ServiceHealthMapping.notificationPermission(report.permissions),
            urgentLowAlarm: ServiceHealthMapping.urgentLowAlarm(report.urgentLowAlarm),
            criticalAlerts: ServiceHealthMapping.criticalAlerts(report.permissions),
            alarmVolume: ServiceHealthMapping.alarmVolume(report.outputVolume),
            issues: ServiceHealthMapping.deliveryIssues(report.problems)
        )
    }

    /// The last finished import (Settings › Data), nil while none has finished.
    static func lastImport(_ state: HistoryImportState?) -> ImportSummary? {
        guard let state, state.phase == .finished else { return nil }
        let covered: DateInterval? = both(state.coveredFrom, state.coveredTo).flatMap { $0 <= $1 ? DateInterval(start: $0, end: $1) : nil }
        return ImportSummary(origin: state.origin, readingsImported: state.readingsImported, covered: covered,
                             finishedAt: state.finishedAt ?? state.startedAt)
    }

    #if DEBUG
    static func debug(_ replay: ReplayStatus) -> DebugSettings {
        DebugSettings(availableScenarios: replay.availableScenarios, activeScenario: replay.activeScenario, speed: replay.speed,
                      developerLiveOutputsEnabled: replay.developerLiveOutputsEnabled)
    }
    #endif
}

private func both<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

// MARK: - Onboarding

enum OnboardingMapping {
    static func importProgress(_ state: HistoryImportState?) -> ImportProgress? {
        guard let state else { return nil }
        let covered: DateInterval? = both(state.coveredFrom, state.coveredTo).flatMap { $0 <= $1 ? DateInterval(start: $0, end: $1) : nil }
        var error: String?
        if case .failed(let message) = state.phase { error = message }
        var skippedParts: [String] = []
        if state.readingsSkippedByStore > 0 {
            skippedParts.append("\(state.readingsSkippedByStore.formatted()) already stored")
        }
        let skippedEntries = state.skipped.filter { $0.key != "futureDated" }.values.reduce(0, +)
        if skippedEntries > 0 { skippedParts.append("\(skippedEntries.formatted()) entries skipped") }
        return ImportProgress(
            origin: state.origin,
            readingsImported: state.readingsImported,
            covered: covered,
            isFinished: state.phase == .finished,
            errorMessage: error,
            isCancelled: state.phase == .cancelled,
            rejectedFutureDated: max(state.rejectedFutureDated, state.skipped["futureDated"] ?? 0),
            skippedNote: skippedParts.isEmpty ? nil : skippedParts.joined(separator: " · ")
        )
    }

    static func bluetooth(_ authorization: BluetoothAuthorization) -> PermissionState {
        switch authorization {
        case .allowed: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        }
    }

    /// The pairing step after a code was submitted, from the sensor state the source reports. Before
    /// a submission (`.idle`) and once paired, the state doesn't follow the sensor. Review m3: while
    /// in progress, a result counts only after a connection step since the code was submitted
    /// (`sawConnectionStep`), so the previous sensor's state is never shown as this pairing's result.
    static func pairing(current: PairingState, sensorState: SensorState, sawConnectionStep: Bool = true) -> PairingState {
        switch current {
        case .idle, .paired:
            return current
        case .inProgress:
            if !sawConnectionStep { return current }
        case .failed, .couldNotStart:
            break
        }
        switch sensorState {
        case .warmingUp, .active, .gracePeriod, .calibrationNeeded, .calibrationError:
            return .paired
        case .failed(let failure):
            return .failed(failure)
        case .expired:
            return .failed(SensorFailure(kind: .sessionStopped, message: "This sensor's session has ended. Apply a new sensor and enter its code."))
        case .error(let code, let description):
            return .failed(SensorFailure(kind: .other, message: "\(description) (code \(code))."))
        case .notPaired, .searching, .connecting, .authenticating, .bluetoothUnavailable:
            // Still on its way; a failure that was showing stays until the source reports progress.
            if case .failed = current, sensorState == .notPaired { return current }
            return .inProgress
        }
    }

    static func pairingErrorText(_ error: PairingError) -> String {
        switch error {
        case .invalidCode:
            return "Enter the 4 digits printed on the sensor applicator."
        case .credentialStoreFailed(let message):
            return "The pairing couldn't be saved (\(message)). Unlock the phone and try again."
        case .replayActive:
            return "A replay run is active (DEBUG build). Stop it in Settings › Developer first."
        case .noSensorToPairAgain:
            // Surfaced, never retried as a new pairing behind the person's back (review N2).
            return "No sensor is stored on this phone to pair again. Pair it as a new sensor with the code on its applicator."
        case .connectionSettingUnresolved(let message):
            // Review n2 (Integrator A; B to word).
            return "The connection setting couldn't be saved (\(message)), so nothing was paired. Choose Listen or Pair again in Settings › Sensor."
        case .notAvailableInListenMode:
            // D45: pairing does not exist while listening.
            return ConnectionModeText.pairingWhileListening
        }
    }

    /// Evidence that a sensor is set up on this phone: a stored sensor (G7Kit `hasStoredSensor`), or
    /// a state only a paired sensor reports. Connection steps, Bluetooth problems and failures are no
    /// evidence (the simulator, for one, reports Bluetooth unsupported with nothing paired).
    static func sensorIsSetUp(sensorState: SensorState, hasStoredSensor: Bool) -> Bool {
        if hasStoredSensor { return true }
        switch sensorState {
        case .warmingUp, .active, .gracePeriod, .calibrationNeeded, .calibrationError:
            return true
        case .notPaired, .searching, .connecting, .authenticating, .bluetoothUnavailable, .failed, .error, .expired:
            return false
        }
    }

    /// Onboarding is shown at launch when no sensor has been set up here and onboarding was never
    /// completed, unless a replay run is starting (DEBUG UI tests and demos); or when asked for
    /// (`-onboarding`).
    static func showsAtLaunch(sensorState: SensorState, hasStoredSensor: Bool, onboardingCompleted: Bool, replayActive: Bool, arguments: [String]) -> Bool {
        if arguments.contains("-onboarding") { return true }
        if replayActive { return false }
        #if DEBUG
        if arguments.contains("-replayScenario") { return false }
        #endif
        return !onboardingCompleted && !sensorIsSetUp(sensorState: sensorState, hasStoredSensor: hasStoredSensor)
    }
}
