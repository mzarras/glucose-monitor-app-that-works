// Alerts screen (HANDOFF §5, §7.3.3, PROGRESS D17, D27, D53): every alert with its threshold, style
// (sound / vibrate only / silent), sound-on-silent and on/off; quiet hours; per-alert detail with the
// style choice, sound picker and preview; "Set all to vibrate except urgent low and Low" (D54).
// Ranges come from AlertEngine's `AlertLimits` (via the rows' `allowed`, `AlertKind.snoozeRange`).
//
// S7: urgent low shows "Always on" instead of a toggle, has no style choice (always sound), its
// sound-on-silent is fixed on, and its snooze choices stop at 30 minutes. AlertEngine enforces the same rules; this screen never offers
// the option in the first place.

import AlertEngine
import SwiftUI
import WidgetCore

struct AlertsActions {
    /// Every settings change (`AlertsMapping.apply` → `AppServices.updateAlertSettings`).
    var edit: @MainActor (AlertEdit) -> Void
    /// Plays the sound once. Returns false (and plays nothing) while an alert's sound is playing.
    var previewSound: @MainActor (AlertSoundID) -> Bool
    var stopSoundPreview: @MainActor () -> Void

    static var noop: AlertsActions {
        AlertsActions(edit: { _ in }, previewSound: { _ in true }, stopSoundPreview: {})
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
    @State private var confirmingVibrateAll = false

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
            vibrateAll
            ForEach(AlertSection.allCases, id: \.self) { section in
                let rows = state.rows(in: section)
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel(section.rawValue).padding(.bottom, 4)
                        if section == .expiryReminders {
                            Text(verbatim: AlertsText.expiryRemindersNote)
                                .font(Typography.body(size: 12))
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 4)
                        }
                        ForEach(rows) { row in
                            AlertListRow(row: row, soundName: state.soundName(row.soundID), actions: actions)
                            Hairline()
                        }
                    }
                }
            }
            QuietHoursSection(quietHours: state.quietHours, setQuietHours: { actions.edit(.quietHours($0)) })
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    /// D53/D54: one tap (confirmed) turns every alert on Sound but urgent low and Low to vibrate
    /// only; the confirmation names each one, and each can be changed back on its page. Offered while
    /// any alert would change.
    @ViewBuilder
    private var vibrateAll: some View {
        if !state.vibrateAllKinds.isEmpty {
            Button(AlertsText.vibrateAllButton) { confirmingVibrateAll = true }
                .buttonStyle(LinkButtonStyle())
                .frame(minHeight: Layout.minTarget)
                .accessibilityIdentifier("alerts.vibrateAll")
                .confirmationDialog(AlertsText.vibrateAllTitle, isPresented: $confirmingVibrateAll, titleVisibility: .visible) {
                    Button(AlertsText.vibrateAllConfirm) { actions.edit(.vibrateAllExceptUrgentLowAndLow) }
                } message: {
                    Text(verbatim: AlertsText.vibrateAllMessage(state.vibrateAllKinds))
                }
        }
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
            .accessibilityIdentifier("alerts.row.\(row.kind.rawValue)")

            if row.kind.canBeDisabled {
                Toggle(isOn: Binding(get: { row.isEnabled }, set: { actions.edit(.enabled(row.kind, $0)) })) {
                    Text(verbatim: row.kind.title)
                }
                .labelsHidden()
                .frame(minHeight: Layout.minTarget)
                .accessibilityIdentifier("alerts.toggle.\(row.kind.rawValue)")
            } else {
                Text(verbatim: "ALWAYS ON")
                    .monoLabel(size: 10, medium: true)
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel(Text("Always on. Can't be turned off."))
            }
        }
        .padding(.vertical, 8)
    }

    /// "≤ 70 mg/dL · Low chime · sounds on silent", "≤ 70 mg/dL · vibrate only", "no sound"
    private var detail: String {
        var parts: [String] = []
        if let threshold = AlertsText.threshold(row.threshold) { parts.append(threshold) }
        parts += AlertsText.soundSummary(row, soundName: soundName)
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
                timeRow("From", TimeOfDay(minuteOfDay: quietHours.startMinuteOfDay)) { var q = quietHours; q.startMinuteOfDay = $0.minuteOfDay; setQuietHours(q) }
                timeRow("Until", TimeOfDay(minuteOfDay: quietHours.endMinuteOfDay)) { var q = quietHours; q.endMinuteOfDay = $0.minuteOfDay; setQuietHours(q) }
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
    @State private var previewRefused = false

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
                    Toggle(isOn: Binding(get: { row.isEnabled }, set: { actions.edit(.enabled(row.kind, $0)) })) {
                        Text(verbatim: "On").font(Typography.body(size: 15, weight: .medium))
                    }
                    .frame(minHeight: Layout.minTarget)
                }
                Hairline()
                if let threshold = row.threshold {
                    thresholdEditor(threshold)
                    Hairline()
                }
                styleSection
                Hairline()
                if row.showsSoundSettings {
                    soundOnSilent
                    Hairline()
                }
                if let snooze = row.snoozeMinutes {
                    Picker(selection: Binding(get: { snooze }, set: { actions.edit(.snooze(row.kind, $0)) })) {
                        ForEach(AlertsText.snoozeOptions(for: row.kind, current: snooze), id: \.self) { minutes in
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
                    Stepper(value: Binding(get: { delay }, set: { actions.edit(.delay(row.kind, $0)) }), in: AlertLimits.highDelayMinutes, step: 5) {
                        Text(verbatim: delay == 0 ? "Fire immediately" : "Fire after \(delay) min above")
                            .font(Typography.body(size: 15))
                    }
                    .frame(minHeight: Layout.minTarget)
                    Hairline()
                }
                if let repeatMinutes = row.repeatMinutes {
                    // HANDOFF §4.7: urgent low repeats until acknowledged; the interval may be shorter
                    // than 5 minutes, never longer, and repeating can't be turned off.
                    Stepper(value: Binding(get: { repeatMinutes }, set: { actions.edit(.repeatInterval(row.kind, $0)) }),
                            in: AlertLimits.urgentLowRepeatMinutes, step: 1) {
                        Text(verbatim: "Repeats every \(repeatMinutes) min until acknowledged")
                            .font(Typography.body(size: 15))
                    }
                    .frame(minHeight: Layout.minTarget)
                    Hairline()
                }
                if row.showsSoundSettings {
                    SectionLabel("SOUND")
                    SoundPicker(sounds: sounds, selectedID: row.soundID, select: { actions.edit(.sound(row.kind, $0)) },
                                preview: { previewRefused = !actions.previewSound($0) })
                    if previewRefused {
                        FieldMessage(text: "An alert is sounding, so the preview didn't play.")
                    }
                }
            }
            .padding(.horizontal, Layout.sideMargin)
            .padding(.vertical, 12)
        }
        .editorialScreen()
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { actions.stopSoundPreview() }
    }

    /// D53: Sound / Vibrate only (/ Silent for one-off events). Urgent low has none: a note (S7).
    @ViewBuilder
    private var styleSection: some View {
        if !row.hasStyleChoice {
            Text(verbatim: AlertsText.urgentLowStyleNote)
                .font(Typography.body(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("alerts.detail.styleNote")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("ALERT STYLE")
                Picker(selection: Binding(get: { row.style }, set: { actions.edit(.style(row.kind, $0)) })) {
                    ForEach(row.allowedStyles, id: \.self) { style in
                        Text(verbatim: AlertsText.styleTitle(style)).tag(style)
                    }
                } label: {
                    Text(verbatim: "Alert style")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("alerts.detail.style")
                if let note = AlertsText.styleNote(row.style) {
                    Text(verbatim: note)
                        .font(Typography.body(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("alerts.detail.styleNote")
                }
            }
        }
    }

    @ViewBuilder
    private func thresholdEditor(_ threshold: AlertThreshold) -> some View {
        switch threshold {
        case .glucose(let mgdl, _, let allowed):
            Stepper(value: Binding(get: { mgdl }, set: { actions.edit(.glucoseThreshold(row.kind, $0)) }), in: allowed, step: allowed.count > 60 ? 5 : 1) {
                thresholdLabel(AlertsText.threshold(threshold) ?? "", range: "\(allowed.lowerBound)–\(allowed.upperBound) mg/dL")
            }
        case .rate(let rate, let allowed):
            Stepper(value: Binding(get: { rate }, set: { actions.edit(.rateThreshold(row.kind, $0)) }), in: allowed, step: 0.5) {
                thresholdLabel(AlertsText.threshold(threshold) ?? "", range: "from the sensor-reported rate")
            }
        case .window(let minutes, let allowed):
            Stepper(value: Binding(get: { minutes }, set: { actions.edit(.window(row.kind, $0)) }), in: allowed, step: 5) {
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
            Toggle(isOn: Binding(get: { row.soundOnSilent }, set: { actions.edit(.soundOnSilent(row.kind, $0)) })) {
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
    let selectedID: AlertSoundID?
    let select: @MainActor (AlertSoundID) -> Void
    let preview: @MainActor (AlertSoundID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(sounds) { sound in
                HStack(spacing: 8) {
                    Button {
                        select(sound.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: sound.name).font(Typography.body(size: 15))
                                Text(verbatim: sound.character)
                                    .font(Typography.body(size: 12))
                                    .foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
