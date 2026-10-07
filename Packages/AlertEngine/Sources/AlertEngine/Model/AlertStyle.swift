// How an alert makes itself noticed (PROGRESS.md D53, Michael: most alerts vibrate, the critical
// ones sound). Urgent low has no style: it always sounds, on the loudest available path (S7).

/// An alert's style, for every alert except urgent low.
public enum AlertStyle: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Its named sound; "Sound on silent" applies as before.
    case sound
    /// No audible sound. The notification carries a silent sound file
    /// (`AlertSoundCatalog.vibrateFileName`), so iOS plays the vibration that goes with a
    /// notification sound (governed by Settings → Sounds & Haptics → Haptics); an awake app
    /// vibrates instead of playing audio. Interruption levels and repeats are as for `.sound`.
    case vibrateOnly
    /// One-off announcements only: the banner, no sound, no vibration (D43's sound switch off).
    case silent

    /// Condition alerts (low, high, missed readings, sensor, Bluetooth, Trio, storage, …).
    public static let conditionStyles: [AlertStyle] = [.sound, .vibrateOnly]
    /// One-off announcements (warm-up done, the expiry reminders before the end of the grace period).
    public static let eventStyles: [AlertStyle] = [.sound, .vibrateOnly, .silent]
    /// Urgent low (S7).
    public static let urgentLowStyles: [AlertStyle] = [.sound]
}
