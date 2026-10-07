// iOS: one system vibration for a vibrate-only alert while the app is awake (D53). AudioToolbox's
// vibrate system sound needs no audio session, so the `.playback` session is never activated for
// it. It follows the phone's vibration settings (Settings → Accessibility → Touch → Vibration).

#if os(iOS)
import AudioToolbox

@MainActor
public final class SystemAlertHaptics: AlertHaptics {
    public init() {}

    public func vibrate() {
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
    }
}
#endif
