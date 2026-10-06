// The grace-period countdown on the Now screen (PROGRESS D43): "GRACE PERIOD", a live h:mm:ss to
// the moment readings stop, in the Editorial figure type, and the clock time. Ticks every second
// while the app is open (a 1 s TimelineView of its own, so the rest of the screen keeps its 15 s
// clock). VoiceOver reads it to the minute. At zero the Now screen switches to "Sensor expired"
// (NowRefreshSchedule ticks at the end).

import SwiftUI
import WidgetCore

struct GraceCountdownView: View {
    let end: Date
    /// The moment the screen was built for; the countdown shows this when there is no live clock.
    let now: Date
    var liveClock: (@MainActor () -> Date)?
    var context: DisplayContext = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "GRACE PERIOD")
                .monoLabel(size: 11, medium: true)
                .foregroundStyle(Theme.ink) // the amber is on the rule only: small text needs 4.5:1 (D32)
            GraceCountdownText(end: end, now: now, liveClock: liveClock) { remaining in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: remaining)
                        .font(Typography.figure(size: 44))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(verbatim: "left")
                        .font(Typography.body(size: 14))
                        .foregroundStyle(Theme.muted)
                }
            }
            Text(verbatim: "Readings stop at \(TimeText.time(end, context)). Have a new sensor ready.")
                .font(Typography.body(size: 13))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.band(.high)).frame(width: 3).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("now.graceCountdown")
    }

    /// Read when VoiceOver reaches it (to the minute): "Grace period, 7 hours 40 minutes left.
    /// Readings stop at 8:15 PM."
    private var spokenLabel: String {
        "\(GraceCountdown.spoken(until: end, now: liveClock?() ?? now)). Readings stop at \(TimeText.time(end, context))."
    }
}

/// The h:mm:ss left until `end`: ticking every second against `liveClock`, or once at `now`.
struct GraceCountdownText<Content: View>: View {
    let end: Date
    let now: Date
    let liveClock: (@MainActor () -> Date)?
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        if let liveClock {
            TimelineView(.periodic(from: now, by: 1)) { _ in
                content(GraceCountdown.clock(until: end, now: liveClock()))
            }
        } else {
            content(GraceCountdown.clock(until: end, now: now))
        }
    }
}
