// Alerts screen (HANDOFF §5, §7.3.3, PROGRESS D17): every alert with its threshold, sound,
// sound-on-silent and on/off; quiet hours; per-alert detail with sound picker and preview.
//
// S7: urgent low shows "Always on" instead of a toggle, its sound-on-silent is fixed on, and its
// snooze choices stop at 30 minutes. AlertEngine enforces the same rules; this screen never offers
// the option in the first place.

import SwiftUI
import WidgetCore

struct AlertsActions {
    var setEnabled: @MainActor (AlertKind, Bool) -> Void
    var setThreshold: @MainActor (AlertKind, AlertThreshold) -> Void
    var setSound: @MainActor (AlertKind, String) -> Void
    var setSoundOnSilent: @MainActor (AlertKind, Bool) -> Void
    var setSnooze: @MainActor (AlertKind, Int) -> Void
    var setDelay: @MainActor (AlertKind, Int) -> Void
    var previewSound: @MainActor (String) -> Void
    var setQuietHours: @MainActor (QuietHours) -> Void

    static var noop: AlertsActions {
        AlertsActions(setEnabled: { _, _ in }, setThreshold: { _, _ in }, setSound: { _, _ in }, setSoundOnSilent: { _, _ in },
                      setSnooze: { _, _ in }, setDelay: { _, _ in }, previewSound: { _ in }, setQuietHours: { _ in })
    }
}

struct AlertsScreen: View {
    let state: AlertsViewState
    let actions: AlertsActions

    var body: some View {
        NavigationStack {
            ScrollView {
                AlertsContent(state: state, actions: actions)
            }
            .editorialScreen()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AlertKind.self) { kind in
                if let row = state.row(kind) {
                    AlertDetailView(row: row, sounds: state.sounds, actions: actions)
                }
            }
        }
    }
}

struct AlertsContent: View {
    let state: AlertsViewState
    let actions: AlertsActions

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Alerts")
                    .font(Typography.title(size: 36))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: "EACH ALERT HAS ITS OWN SOUND")
                    .monoLabel(size: 11)
                    .foregroundStyle(Theme.muted)
                Hairline().padding(.top, 6)
            }
            ForEach(AlertSection.allCases, id: \.self) { section in
                let rows = state.rows.filter { $0.kind.section == section }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel(section.rawValue).padding(.bottom, 4)
                        ForEach(rows) { row in
                            AlertListRow(row: row, soundName: state.soundName(row.soundID), actions: actions)
                            Hairline()
                        }
                    }
                }
            }
            QuietHoursSection(quietHours: state.quietHours, setQuietHours: actions.setQuietHours)
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}

struct AlertListRow: View {
    let row: AlertRow
    let soundName: String
    let actions: AlertsActions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            NavigationLink(value: row.kind) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: row.kind.title)
                        .font(Typography.body(size: 15, weight: row.kind == .urgentLow ? .semibold : .medium))
                    Text(verbatim: detail)
                        .font(Typography.label(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !row.kind.canBeDisabled {
                        Text(verbatim: AlertsText.urgentLowNote)
                            .font(Typography.body(size: 12))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Layout.minTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if row.kind.canBeDisabled {
                Toggle(isOn: Binding(get: { row.isEnabled }, set: { actions.setEnabled(row.kind, $0) })) {
                    Text(verbatim: row.kind.title)
                }
                .labelsHidden()
                .frame(minHeight: Layout.minTarget)
            } else {
                Text(verbatim: "ALWAYS ON")
                    .monoLabel(size: 10, medium: true)
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel(Text("Always on. Can't be turned off."))
            }
        }
        .padding(.vertical, 8)
    }

    /// "≤ 70 mg/dL · Low chime · sounds on silent"
    private var detail: String {
        var parts: [String] = []
        if let threshold = AlertsText.threshold(row.threshold) { parts.append(threshold) }
        parts.append(soundName)
        if row.effectiveSoundOnSilent { parts.append("sounds on silent") }
        if !row.effectiveIsEnabled { parts.append("off") }
        return parts.joined(separator: " · ")
    }
}

struct QuietHoursSection: View {
    let quietHours: QuietHours
    let setQuietHours: @MainActor (QuietHours) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("QUIET HOURS")
            Toggle(isOn: Binding(get: { quietHours.isEnabled }, set: { var q = quietHours; q.isEnabled = $0; setQuietHours(q) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Quiet hours · \(AlertsText.quietHoursSchedule(quietHours))").font(Typography.body(size: 15, weight: .medium))
                    Text(verbatim: AlertsText.quietHoursNote)
                        .font(Typography.body(size: 13))
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(minHeight: Layout.minTarget)
            if quietHours.isEnabled {
                timeRow("From", quietHours.start) { var q = quietHours; q.start = $0; setQuietHours(q) }
                timeRow("Until", quietHours.end) { var q = quietHours; q.end = $0; setQuietHours(q) }
            }
            Hairline()
        }
    }

    private func timeRow(_ label: String, _ time: TimeOfDay, set: @escaping @MainActor (TimeOfDay) -> Void) -> some View {
        DatePicker(
            selection: Binding(
                get: { Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date() },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    set(TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0))
                }
            ),
            displayedComponents: .hourAndMinute
        ) {
            Text(verbatim: label).font(Typography.body(size: 14))
        }
        .frame(minHeight: Layout.minTarget)
    }
}

// MARK: - Detail

struct AlertDetailView: View {
    let row: AlertRow
    let sounds: [AlertSound]
    let actions: AlertsActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                Text(verbatim: row.kind.title)
                    .font(Typography.title(size: 32))
                    .accessibilityAddTraits(.isHeader)
                if !row.kind.canBeDisabled {
                    Text(verbatim: AlertsText.urgentLowNote)
                        .font(Typography.body(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle(isOn: Binding(get: { row.isEnabled }, set: { actions.setEnabled(row.kind, $0) })) {
                        Text(verbatim: "On").font(Typography.body(size: 15, weight: .medium))
                    }
                    .frame(minHeight: Layout.minTarget)
                }
                Hairline()
                if let threshold = row.threshold {
                    thresholdEditor(threshold)
                    Hairline()
                }
                soundOnSilent
                Hairline()
                if let snooze = row.snoozeMinutes {
                    Picker(selection: Binding(get: { snooze }, set: { actions.setSnooze(row.kind, $0) })) {
                        ForEach(AlertsText.snoozeOptions(for: row.kind), id: \.self) { minutes in
                            Text(verbatim: "\(minutes) min").tag(minutes)
                        }
                    } label: {
                        Text(verbatim: "Snooze for").font(Typography.body(size: 15))
                    }
                    .pickerStyle(.menu)
                    .frame(minHeight: Layout.minTarget)
                    Hairline()
                }
                if let delay = row.delayMinutes {
                    Stepper(value: Binding(get: { delay }, set: { actions.setDelay(row.kind, $0) }), in: 0...60, step: 5) {
                        Text(verbatim: delay == 0 ? "Fire immediately" : "Fire after \(delay) min above")
                            .font(Typography.body(size: 15))
                    }
                    .frame(minHeight: Layout.minTarget)
                    Hairline()
                }
                if let repeatMinutes = row.repeatMinutes {
                    Text(verbatim: "Repeats every \(repeatMinutes) min until acknowledged.")
                        .font(Typography.body(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                SectionLabel("SOUND")
                SoundPicker(sounds: sounds, selectedID: row.soundID, select: { actions.setSound(row.kind, $0) }, preview: actions.previewSound)
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
        .editorialScreen()
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func thresholdEditor(_ threshold: AlertThreshold) -> some View {
        switch threshold {
        case .glucose(let mgdl, let isBelow, let allowed):
            Stepper(value: Binding(get: { mgdl }, set: { actions.setThreshold(row.kind, .glucose(mgdl: $0, isBelow: isBelow, allowed: allowed)) }), in: allowed, step: allowed.count > 60 ? 5 : 1) {
                thresholdLabel(AlertsText.threshold(threshold) ?? "", range: "\(allowed.lowerBound)–\(allowed.upperBound) mg/dL")
            }
        case .rate(let rate, let allowed):
            Stepper(value: Binding(get: { rate }, set: { actions.setThreshold(row.kind, .rate(mgdlPerMinute: $0, allowed: allowed)) }), in: allowed, step: 0.5) {
                thresholdLabel(AlertsText.threshold(threshold) ?? "", range: "from the sensor-reported rate")
            }
        case .window(let minutes, let allowed):
            Stepper(value: Binding(get: { minutes }, set: { actions.setThreshold(row.kind, .window(minutes: $0, allowed: allowed)) }), in: allowed, step: 5) {
                thresholdLabel(AlertsText.threshold(threshold) ?? "", range: "\(allowed.lowerBound)–\(allowed.upperBound) min")
            }
        case .projected:
            thresholdLabel(AlertsText.threshold(threshold) ?? "", range: "uses the sensor-reported rate only")
        }
    }

    private func thresholdLabel(_ value: String, range: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value).font(Typography.title(size: 22))
            Text(verbatim: range).font(Typography.label(size: 11)).foregroundStyle(Theme.muted)
        }
        .frame(minHeight: Layout.minTarget)
    }

    @ViewBuilder
    private var soundOnSilent: some View {
        if row.kind.soundOnSilentIsFixed {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Sound on silent").font(Typography.body(size: 15, weight: .medium))
                    Text(verbatim: AlertsText.soundOnSilentNote).font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Text(verbatim: "ALWAYS").monoLabel(size: 10, medium: true)
            }
            .frame(minHeight: Layout.minTarget)
            .accessibilityElement(children: .combine)
        } else {
            Toggle(isOn: Binding(get: { row.soundOnSilent }, set: { actions.setSoundOnSilent(row.kind, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Sound on silent").font(Typography.body(size: 15, weight: .medium))
                    Text(verbatim: AlertsText.soundOnSilentNote).font(Typography.body(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .frame(minHeight: Layout.minTarget)
        }
    }
}

struct SoundPicker: View {
    let sounds: [AlertSound]
    let selectedID: String?
    let select: @MainActor (String) -> Void
    let preview: @MainActor (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sounds) { sound in
                HStack(spacing: 8) {
                    Button {
                        select(sound.id)
                    } label: {
                        HStack {
                            Text(verbatim: sound.name).font(Typography.body(size: 15))
                            Spacer()
                            if sound.id == selectedID {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(minHeight: Layout.minTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(sound.id == selectedID ? .isSelected : [])
                    Button {
                        preview(sound.id)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 20, weight: .light))
                            .frame(width: Layout.minTarget, height: Layout.minTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Preview \(sound.name)"))
                }
                Hairline()
            }
        }
    }
}
