// Sample view states for previews, screenshots and the DEBUG launch until Phase 2 wires real data.
// DEBUG only: a Release build contains no sample value to show (S1).
//
// All values are made up. Curves are deterministic so screenshots are stable.

#if DEBUG
import AlertEngine
import Foundation
import GlucoseCore
import WidgetCore

enum Fixtures {
    /// Wed 23 Sep 2026, 12:35 PM in New York (16:35 UTC): the mockups' time, for screenshots.
    static let referenceNow = Date(timeIntervalSince1970: 1_790_181_300)

    // MARK: - Readings

    /// The mockup's last three hours: 82 → ~120 → 105, one reading every 5 minutes.
    static func mockupCurve(minutesBeforeEnd m: Double) -> Int {
        let x = 1 - m / 180
        return Int((82 + 23 * x + 26 * sin(Double.pi * x)).rounded())
    }

    /// Earlier in the day: gentle meal bumps.
    static func dayCurve(minutesBeforeEnd m: Double) -> Int {
        let hours = m / 60
        return Int((128 + 34 * sin(hours / 3.1) + 12 * sin(hours / 0.9)).rounded())
    }

    /// 24 h of 5-minute points ending `lastReadingAge` minutes before `now`, with one 40-minute gap
    /// about ten hours back (so the 12H/24H charts show a broken line).
    static func dayOfPoints(now: Date, lastReadingAge: Double = 3, tail: (Double) -> GlucoseValue? = { _ in nil }) -> [ChartPoint] {
        let end = now.addingTimeInterval(-lastReadingAge * 60)
        var points: [ChartPoint] = []
        for step in stride(from: 24 * 12, through: 0, by: -1) {
            let m = Double(step * 5)
            if (590...630).contains(m) { continue } // signal gap
            let value: GlucoseValue
            if let custom = tail(m) {
                value = custom
            } else if m <= 180 {
                value = .mgdl(mockupCurve(minutesBeforeEnd: m))
            } else {
                value = .mgdl(dayCurve(minutesBeforeEnd: m))
            }
            points.append(ChartPoint(date: end.addingTimeInterval(-m * 60), value: value))
        }
        return points
    }

    static func latest(from points: [ChartPoint], trend: TrendArrow) -> LatestReading? {
        guard let last = points.last else { return nil }
        let previous = points.count >= 2 ? points[points.count - 2] : nil
        let delta = previous.flatMap {
            GlucoseDelta.between(latestDate: last.date, latestValue: last.value, previousDate: $0.date, previousValue: $0.value)
        }
        return LatestReading(date: last.date, value: last.value, trend: trend, delta: delta)
    }

    // MARK: - Now

    enum NowScenario: String, CaseIterable, Identifiable {
        case normal, low, high, lowFlag, highFlag, stale, noData, warmUp, expired, bluetoothOff, trioFailing, sensorError,
             transientFailure, pairingRejected, sensorEnded, sensorProblem, calibrationNeeded, calibrationThenClockMismatch,
             notPaired, clockMismatch, manyProblems, gracePeriod
        var id: String { rawValue }
    }

    static func activeSensor(now: Date) -> SensorState {
        .active(sessionStart: now.addingTimeInterval(-(5 * 86_400 + 16 * 3_600)), expiresAt: now.addingTimeInterval(4 * 86_400 + 7 * 3_600 + 20 * 60))
    }

    static func healthyServices(now: Date) -> ServiceHealth {
        ServiceHealth(
            trio: .ok(lastHandoff: now.addingTimeInterval(-3 * 60)),
            nightscout: .ok(lastUpload: now.addingTimeInterval(-3 * 60)),
            dexcomShare: .ok(lastUpload: now.addingTimeInterval(-3 * 60)),
            notifications: .authorized,
            alarmVolume: .ok(level: 0.8),
            urgentLowAlarm: .authorized,
            forceQuitGap: nil
        )
    }

    static func now(_ scenario: NowScenario, at now: Date = referenceNow) -> NowViewState {
        var points = dayOfPoints(now: now)
        var trend = TrendArrow.flat
        var sensor = activeSensor(now: now)
        var health = healthyServices(now: now)
        var fingersticks = [FingerstickMarker(date: now.addingTimeInterval(-95 * 60), mgdl: 116)]
        var today = TodaySummary(timeInRangePercent: 82, averageMgdl: 121, lowCount: 0)

        switch scenario {
        case .normal, .manyProblems:
            break
        case .low:
            points = dayOfPoints(now: now, lastReadingAge: 2) { m in m <= 40 ? .mgdl(Int(62 + m * 0.9)) : nil }
            trend = .fortyFiveDown
            today = TodaySummary(timeInRangePercent: 74, averageMgdl: 112, lowCount: 1)
        case .high:
            points = dayOfPoints(now: now, lastReadingAge: 1) { m in m <= 60 ? .mgdl(Int(232 - m * 1.6)) : nil }
            trend = .singleUp
            today = TodaySummary(timeInRangePercent: 61, averageMgdl: 164, lowCount: 0)
        case .lowFlag:
            points = dayOfPoints(now: now, lastReadingAge: 1) { m in
                if m <= 10 { return .belowRange }
                if m <= 45 { return .mgdl(Int(41 + (m - 10) * 0.8)) }
                return nil
            }
            trend = .fortyFiveDown
            today = TodaySummary(timeInRangePercent: 70, averageMgdl: 104, lowCount: 2)
        case .highFlag:
            points = dayOfPoints(now: now, lastReadingAge: 2) { m in
                if m <= 5 { return .aboveRange }
                if m <= 60 { return .mgdl(Int(398 - (m - 5) * 2.5)) }
                return nil
            }
            trend = .doubleUp
            today = TodaySummary(timeInRangePercent: 48, averageMgdl: 205, lowCount: 0)
        case .stale:
            points = dayOfPoints(now: now, lastReadingAge: 12)
        case .noData:
            points = dayOfPoints(now: now, lastReadingAge: 47)
        case .warmUp:
            points = []
            fingersticks = []
            sensor = .warmingUp(endsAt: now.addingTimeInterval(72 * 60))
            today = TodaySummary(timeInRangePercent: nil, averageMgdl: nil, lowCount: nil)
            health.trio = .ok(lastHandoff: nil)
        case .expired:
            points = dayOfPoints(now: now, lastReadingAge: 31)
            sensor = .expired
        case .gracePeriod:
            // D43: 7 h 40 min 12 s of the 12-hour grace period left; readings still arrive.
            sensor = .gracePeriod(endsAt: now.addingTimeInterval(7 * 3_600 + 40 * 60 + 12))
        case .bluetoothOff:
            sensor = .bluetoothUnavailable(.poweredOff)
        case .clockMismatch:
            // The phone clock was moved back an hour: the latest reading is dated in the future.
            points = dayOfPoints(now: now, lastReadingAge: -60)
        case .trioFailing:
            health.trio = .failing(since: now.addingTimeInterval(-18 * 60), message: "App Group write failed")
        case .sensorError:
            points = dayOfPoints(now: now, lastReadingAge: 6)
            sensor = .error(code: 7, description: "Sensor signal error")
        case .transientFailure:
            // A real reading 2 min old stays visible; the warning banner explains (D36).
            points = dayOfPoints(now: now, lastReadingAge: 2)
            sensor = .failed(SensorFailure(kind: .otherAppRejected, message: "Another app on this phone is connected to the sensor. Close it or remove it."))
        case .pairingRejected:
            points = dayOfPoints(now: now, lastReadingAge: 4)
            sensor = .failed(SensorFailure(kind: .pairingRejected, message: "The sensor didn't accept this phone. Pair it again with the 4-digit code on the applicator."))
        case .sensorEnded:
            points = dayOfPoints(now: now, lastReadingAge: 8)
            sensor = .failed(SensorFailure(kind: .sensorFailed, message: "The sensor has failed and won't send more readings. Replace it."))
        case .sensorProblem:
            points = dayOfPoints(now: now, lastReadingAge: 4)
            sensor = .failed(SensorFailure(kind: .other, message: "The sensor reported a status this app doesn't recognise (0x2A)."))
        case .calibrationNeeded:
            points = dayOfPoints(now: now, lastReadingAge: 7)
            sensor = .calibrationNeeded(code: 4)
        case .calibrationThenClockMismatch:
            // Review minor 4: the sensor asked for a calibration, then the phone clock went wrong.
            points = dayOfPoints(now: now, lastReadingAge: 25)
            sensor = .failed(SensorFailure(kind: .clockMismatch, message: "This phone's clock doesn't match the sensor's. Check Date & Time."))
        case .notPaired:
            points = []
            fingersticks = []
            sensor = .notPaired
            health = .unconfigured
            today = TodaySummary(timeInRangePercent: nil, averageMgdl: nil, lowCount: nil)
        }
        if scenario == .manyProblems {
            health.notifications = .denied
            health.alarmVolume = .tooLow(level: 0.15) // D55: Settings shows it; no Now banner
            health.urgentLowAlarm = .denied
            health.nightscout = .failing(failureCount: 3, lastError: "HTTP 401 Unauthorized.", since: now.addingTimeInterval(-20 * 60))
            health.forceQuitGap = ForceQuitGap(from: now.addingTimeInterval(-5 * 3_600), to: now.addingTimeInterval(-3.5 * 3_600))
        }

        var state = NowViewState(
            latestLiveReading: latest(from: points, trend: trend),
            sensorState: sensor,
            chartPoints: points,
            fingersticks: fingersticks,
            chartWindow: .threeHours,
            today: today,
            health: health,
            replayScenario: nil
        )
        state.sensorNeedsCalibration = scenario == .calibrationNeeded || scenario == .calibrationThenClockMismatch
        return state
    }

    /// The kinds of messages a source gives for pairing problems (D36). Wording is sample text.
    static func pairingFailure(_ kind: SensorFailure.Kind) -> SensorFailure {
        switch kind {
        case .bluetoothPairingIncomplete:
            return SensorFailure(kind: kind, message: "iOS pairing was cancelled or timed out. Keep the phone near the sensor and tap Pair when iOS asks.")
        case .pairingRejected:
            return SensorFailure(kind: kind, message: "The sensor didn't accept the pairing code. Check the 4 digits on the applicator and try again.")
        case .pairingCodeNeeded:
            return SensorFailure(kind: kind, message: "This sensor needs its 4-digit pairing code.")
        case .bondRemoved:
            return SensorFailure(kind: kind, message: "The sensor no longer recognises this phone. Pair it again with the code on the applicator.")
        case .unsupportedSensor:
            return SensorFailure(kind: kind, message: "This sensor type isn't supported (only G7 10-day sensors are).")
        case .credentialsUnavailable:
            return SensorFailure(kind: kind, message: "The sensor's saved pairing keys can't be read. They become available after you unlock the phone.")
        default:
            return SensorFailure(kind: kind, message: "Pairing failed.")
        }
    }

    // MARK: - Calibration

    enum CalibrationScenario: String, CaseIterable, Identifiable {
        case available, pending, accepted, rejected, unknown, refused, warmingUp
        var id: String { rawValue }
    }

    static func calibration(_ scenario: CalibrationScenario, at now: Date = referenceNow) -> CalibrationViewState {
        let nowState = Fixtures.now(.normal, at: now)
        let request = CalibrationRequest(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, mgdl: 112, takenAt: now.addingTimeInterval(-60))
        var state = CalibrationViewState(sensorState: nowState.sensorState, latestLiveReading: nowState.latestLiveReading, acceptedRange: 40...400, lastSubmission: nil)
        switch scenario {
        case .available: break
        case .pending: state.lastSubmission = CalibrationSubmission(request: request, outcome: .status(.queued), updatedAt: now)
        case .accepted: state.lastSubmission = CalibrationSubmission(request: request, outcome: .status(.accepted), updatedAt: now)
        case .rejected: state.lastSubmission = CalibrationSubmission(request: request, outcome: .status(.rejected(code: 3, reason: "Glucose is changing too fast")), updatedAt: now)
        case .unknown: state.lastSubmission = CalibrationSubmission(request: request, outcome: .status(.unknown(description: "The sensor sent an unrecognised response")), updatedAt: now)
        case .refused: state.lastSubmission = CalibrationSubmission(request: request, outcome: .refused(.notAuthenticated), updatedAt: now)
        case .warmingUp:
            state.sensorState = .warmingUp(endsAt: now.addingTimeInterval(72 * 60))
            state.latestLiveReading = nil
        }
        return state
    }

    // MARK: - Trends

    /// AGP-like percentile curves: low before dawn, bumps after meals.
    static func agpBuckets(scale: Double = 1) -> [AGPBucket] {
        func bump(_ m: Double, _ centre: Double, _ width: Double) -> Double {
            exp(-pow((m - centre) / width, 2) / 2)
        }
        return stride(from: 0, to: 1_440, by: 15).map { minute in
            let m = Double(minute)
            let p50 = 104 + scale * (44 * bump(m, 510, 60) + 38 * bump(m, 790, 70) + 50 * bump(m, 1_140, 80)) - 8 * bump(m, 240, 90)
            let lift = max(0, p50 - 104)
            return AGPBucket(
                minuteOfDay: minute,
                p5: p50 - 36 - 0.1 * lift,
                p25: p50 - 17 - 0.1 * lift,
                p50: p50,
                p75: p50 + 22 + 0.25 * lift,
                p95: p50 + 64 + 0.4 * lift
            )
        }
    }

    static func dayTraces(count: Int, now: Date) -> [DayTrace] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        return (0..<count).map { offset in
            let dayStart = calendar.date(byAdding: .day, value: -offset, to: todayStart)!
            let end = offset == 0 ? now.addingTimeInterval(-3 * 60) : calendar.date(byAdding: .day, value: 1, to: dayStart)!.addingTimeInterval(-60)
            var points: [ChartPoint] = []
            var date = dayStart
            while date <= end {
                let m = date.timeIntervalSince(dayStart) / 60
                let wobble = 14 * sin(m / 47 + Double(offset))
                let meals = 42 * exp(-pow((m - 500 - Double(offset) * 25) / 55, 2) / 2) + 48 * exp(-pow((m - 1_150) / 70, 2) / 2)
                let value = Int((110 + wobble + meals - Double(offset) * 6).rounded())
                if !(offset == 1 && (200...250).contains(m)) { // a gap on yesterday
                    points.append(ChartPoint(date: date, value: .mgdl(value)))
                }
                date.addTimeInterval(5 * 60)
            }
            return DayTrace(dayStart: dayStart, isToday: offset == 0, points: points)
        }
    }

    static func trends(_ period: TrendsPeriod, at now: Date = referenceNow) -> TrendsViewState {
        let start = Calendar.current.date(byAdding: .day, value: -(period.days - 1), to: Calendar.current.startOfDay(for: now))!
        var state = TrendsViewState(
            period: period,
            interval: DateInterval(start: start, end: now),
            timeInRange: 78,
            timeInRangeChange: 4,
            rangeBins: RangeBins(veryLow: 1, low: 5, inRange: 78, high: 14, veryHigh: 2),
            profile: period.showsDailyTraces ? .days(dayTraces(count: period.days, now: now)) : .percentiles(agpBuckets()),
            tightRange: 61,
            meanMgdl: 128,
            gmiPercent: 3.31 + 0.02392 * 128,
            cvPercent: 31,
            lows: LowsSummary(count: 6, meanDurationMinutes: 32, peakWindow: HourWindow(startHour: 2, endHour: 5, count: 4)),
            overnightTimeInRange: 84,
            longestInRangeStreak: 11 * 3_600 + 20 * 60,
            afterExerciseTimeInRange: 71,
            dataSufficiency: 94,
            importedData: nil
        )
        switch period {
        case .oneDay:
            state.timeInRange = 82
            state.timeInRangeChange = -3
            state.rangeBins = RangeBins(veryLow: 0, low: 2, inRange: 82, high: 15, veryHigh: 1)
            state.lows = LowsSummary(count: 0, meanDurationMinutes: nil, peakWindow: nil)
        case .threeDays:
            state.timeInRange = 80
            state.timeInRangeChange = 2
            state.lows = LowsSummary(count: 1, meanDurationMinutes: 25, peakWindow: nil)
        case .thirtyDays:
            state.dataSufficiency = 64
            state.timeInRange = 76
        case .ninetyDays:
            state.timeInRange = 74
            state.timeInRangeChange = nil
            state.importedData = ImportedDataNote(
                origins: [.nightscout],
                interval: DateInterval(start: start, end: start.addingTimeInterval(62 * 86_400))
            )
        case .sevenDays, .fourteenDays:
            break
        }
        return state
    }

    // MARK: - Alerts

    /// The bundled sounds, as the Alerts screen lists them.
    static var sounds: [AlertSound] { alerts.sounds }

    /// AlertEngine's own defaults (HANDOFF §5), mapped exactly as the running app maps them.
    static let alerts = AlertsMapping.make(AlertSettings.defaults)

    // MARK: - Settings

    static func settings(at now: Date = referenceNow) -> SettingsViewState {
        SettingsViewState(
            sensor: SensorSettings(state: activeSensor(now: now), serial: "SAMPLE0001"),
            trio: TrioSettings(isEnabled: true, status: .ok(lastHandoff: now.addingTimeInterval(-3 * 60))),
            nightscout: NightscoutSettings(url: "https://nightscout.example.com", hasToken: true, uploadEnabled: true, status: .ok(lastUpload: now.addingTimeInterval(-3 * 60))),
            dexcomShare: DexcomShareSettings(isEnabled: true, username: "share-user", hasPassword: true, region: .us, status: .ok(lastUpload: now.addingTimeInterval(-3 * 60))),
            delivery: AlertDeliveryStatus(notifications: .authorized, urgentLowAlarm: .authorized, criticalAlerts: .entitlementNotGranted, alarmVolume: .ok(level: 0.8)),
            lastImport: ImportSummary(origin: .nightscout, readingsImported: 25_412, covered: DateInterval(start: now.addingTimeInterval(-90 * 86_400), end: now.addingTimeInterval(-6 * 86_400)), finishedAt: now.addingTimeInterval(-6 * 86_400)),
            accent: .forest,
            appearance: .system,
            unit: .mgdL,
            retention: .twoYears,
            databaseSizeBytes: 18_400_000,
            appVersion: "0.1.0 (1)"
        )
    }

    /// D45/D47 design (not wired yet): listening alongside the Dexcom app, packet recording on.
    static func settingsListening(at now: Date = referenceNow) -> SettingsViewState {
        var state = settings(at: now)
        state.connection = ConnectionModeState(mode: .listen)
        state.packetRecording = PacketRecordingState(isOn: true)
        return state
    }

    /// D55: everything fine except the alarm volume (15 %): the compact notice at the top.
    static func settingsVolumeLow(at now: Date = referenceNow) -> SettingsViewState {
        var state = settings(at: now)
        state.delivery.alarmVolume = .tooLow(level: 0.15)
        return state
    }

    static func settingsWithProblems(at now: Date = referenceNow) -> SettingsViewState {
        var state = settings(at: now)
        state.trio.status = .failing(since: now.addingTimeInterval(-18 * 60), message: "App Group write failed")
        state.nightscout.status = .failing(failureCount: 3, lastError: "HTTP 401 Unauthorized", since: now.addingTimeInterval(-20 * 60))
        state.delivery = AlertDeliveryStatus(notifications: .denied, urgentLowAlarm: .denied, criticalAlerts: .disabledByUser, alarmVolume: .tooLow(level: 0.15))
        return state
    }

    // MARK: - Onboarding

    static func onboarding(_ step: OnboardingStep, at now: Date = referenceNow) -> OnboardingState {
        var state = OnboardingState.initial
        state.step = step
        switch step {
        case .importHistory:
            state.importProgress = ImportProgress(origin: .nightscout, readingsImported: 12_408, covered: DateInterval(start: now.addingTimeInterval(-43 * 86_400), end: now), isFinished: false, errorMessage: nil)
        case .permissions:
            state.bluetooth = .granted
            state.notifications = .notDetermined
        case .alarms:
            state.bluetooth = .granted
            state.notifications = .authorized
            state.urgentLowAlarm = .notDetermined
        case .pairing:
            state.bluetooth = .granted
            state.notifications = .authorized
        case .warmUp:
            state.pairing = .paired
            state.sensorState = .warmingUp(endsAt: now.addingTimeInterval(27 * 60))
        case .connection:
            state.connection = ConnectionModeState(mode: nil) // the person always chooses (D45)
        case .listen:
            state.connection = ConnectionModeState(mode: .listen)
            state.bluetooth = .granted
            state.notifications = .authorized
            state.sensorState = .active(sessionStart: now.addingTimeInterval(-3 * 86_400), expiresAt: now.addingTimeInterval(7 * 86_400))
        case .welcome, .removeDexcomApp:
            break
        }
        return state
    }
}
#endif
