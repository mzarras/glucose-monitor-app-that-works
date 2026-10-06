// Every alert the app can raise (HANDOFF §5). One case per row/sub-row of the §5 table, plus
// Bluetooth (S5, PROGRESS.md D9) and "sensor expired" (S5 names expiring *and* expired).

/// An alert the engine can raise.
///
/// The declaration order is the priority order: when two alerts want the in-app audio at once,
/// the one declared earlier wins (`AlertKind.priority`). Urgent low is first.
public enum AlertKind: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Glucose at or below the urgent-low threshold (default 55 mg/dL), or the sensor LOW flag.
    /// Cannot be disabled (S7).
    case urgentLow
    /// The sensor-reported trend rate projects glucose to reach the urgent-low threshold within
    /// 20 minutes. Off by default.
    case urgentLowSoon
    /// Glucose at or below the low threshold (default 70 mg/dL), or the sensor LOW flag.
    case low
    /// Glucose at or above the high threshold (default 250 mg/dL), or the sensor HIGH flag.
    case high
    /// Sensor-reported rate at or below −threshold (default 3 mg/dL/min). Off by default.
    case fallingFast
    /// Sensor-reported rate at or above +threshold (default 3 mg/dL/min). Off by default.
    case risingFast
    /// No valid reading for the configured window (default 15 minutes). S5.
    case missedReadings
    /// The sensor finished warming up.
    case sensorWarmUpComplete
    /// The sensor session ends within 24 hours.
    case sensorExpiringIn24Hours
    /// The sensor session ends within 2 hours.
    case sensorExpiringIn2Hours
    /// The sensor entered its grace period.
    case sensorGracePeriod
    /// The sensor is finished (replace it) or no longer accepts this phone (pair again): only
    /// `SensorFailure.raisesSensorAlert` failures (D36). Transient failures raise nothing; missed
    /// readings covers a long gap. S5.
    case sensorFailed
    /// The sensor or transmitter reported an error. S5.
    case sensorError
    /// The sensor withholds readings until it is calibrated, or rejected a calibration (D36).
    case calibrationNeeded
    /// The sensor session has ended (grace period over). S5.
    case sensorExpired
    /// Bluetooth is off, unauthorized, or unsupported, so no readings can arrive. S5.
    case bluetoothUnavailable
    /// Writes to Trio's App Group fail, or Trio has stopped consuming readings. S5.
    case trioBridge
    /// The reading store has failed for 5 minutes or more: history is not being saved (D42). S5.
    case storageFailing

    /// Lower number = more important. Used only to decide which sound keeps the speaker.
    public var priority: Int { Self.allCases.firstIndex(of: self) ?? Int.max }

    /// Alerts driven by the value or rate of the latest live reading.
    public var isGlucoseAlert: Bool {
        switch self {
        case .urgentLow, .urgentLowSoon, .low, .high, .fallingFast, .risingFast: return true
        default: return false
        }
    }

    /// One-off announcements (fire once per sensor session, never repeat). Everything else is a
    /// *condition* alert with the armed → firing → snoozed → cleared lifecycle.
    public var isEventAlert: Bool {
        switch self {
        case .sensorWarmUpComplete, .sensorExpiringIn24Hours, .sensorExpiringIn2Hours, .sensorGracePeriod:
            return true
        default:
            return false
        }
    }

    /// Alerts whose repeats are pre-scheduled as pending notifications, because the app may be
    /// suspended when they are due (HANDOFF §4.7): the urgent-low 5-minute repeats and the
    /// missed-readings alert (which by definition fires while no BLE event wakes the app).
    public var usesScheduledNotifications: Bool {
        self == .urgentLow || self == .missedReadings
    }
}
