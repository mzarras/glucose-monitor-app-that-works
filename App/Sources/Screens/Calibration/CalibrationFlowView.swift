// Calibration sheet (PROGRESS D16): enter → retype to confirm → "are you sure" when far from the
// sensor or not comparable → submit → status. The fingerstick value is always labelled as a
// fingerstick, never shown as a glucose reading, never plotted on the sensor line (S1).

import GlucoseCore
import SwiftUI
import WidgetCore

struct CalibrationFlowView: View {
    let state: CalibrationViewState
    let submit: @MainActor (CalibrationRequest) -> Void
    let close: @MainActor () -> Void
    /// Drawn on top in DEBUG builds (D19, review M3). Nil in Release.
    let buildBanner: BuildBanner?
    @State private var flow: CalibrationFlow

    init(state: CalibrationViewState, initialFlow: CalibrationFlow = CalibrationFlow(),
         buildBanner: BuildBanner? = BuildBanner.forThisBuild(replayScenario: nil),
         submit: @escaping @MainActor (CalibrationRequest) -> Void, close: @escaping @MainActor () -> Void) {
        self.state = state
        self.submit = submit
        self.close = close
        self.buildBanner = buildBanner
        _flow = State(initialValue: initialFlow)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let buildBanner {
                BuildBannerView(banner: buildBanner)
            }
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                CalibrationContent(state: state, flow: $flow, now: timeline.date, submit: submit, close: close)
            }
        }
        .editorialScreen()
    }
}

struct CalibrationContent: View {
    let state: CalibrationViewState
    @Binding var flow: CalibrationFlow
    let now: Date
    let submit: @MainActor (CalibrationRequest) -> Void
    let close: @MainActor () -> Void
    /// Off only for `ImageRenderer` screenshots, which do not draw ScrollView content.
    var scrolls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: "Calibrate sensor")
                    .font(Typography.title(size: 26))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: Layout.minTarget, height: Layout.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            Hairline().padding(.bottom, 12)
            if scrolls {
                ScrollView { steps }
            } else {
                steps
            }
        }
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 16)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .entry:
            switch CalibrationRules.availability(state, now: now) {
            case .available:
                if let range = state.acceptedRange { entry(range) }
            case .unavailable(let reason):
                unavailable(reason)
            }
        case .confirm(let value, let takenAt):
            confirm(value, takenAt: takenAt)
        case .largeDifference(let value, _, let difference):
            largeDifference(value, difference: difference)
        case .submitted(let request):
            submitted(request)
        }
    }

    // MARK: Steps

    private func unavailable(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Calibration isn't available right now.").font(Typography.body(size: 15, weight: .semibold))
            Text(verbatim: reason).font(Typography.body(size: 14)).fixedSize(horizontal: false, vertical: true)
            Button("Close", action: close).buttonStyle(SecondaryButtonStyle())
        }
    }

    private func entry(_ range: ClosedRange<Int>) -> some View {
        let parsed = CalibrationRules.parse(flow.entryText, acceptedRange: range)
        return VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Use a fresh fingerstick from washed, dry hands. The sensor adjusts its readings to this value, and Trio doses from those readings.")
                .font(Typography.body(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: sensorNow)
                .font(Typography.label(size: 11))
                .foregroundStyle(Theme.muted)
            if let advice = CalibrationRules.trendAdvice(latest: state.latestLiveReading) {
                WarningNote(text: advice)
            }
            ValueField(label: "FINGERSTICK, MG/DL", text: $flow.entryText)
            switch parsed {
            case .invalid:
                FieldMessage(text: "Whole numbers only.")
            case .outOfRange(let accepted):
                FieldMessage(text: "The sensor accepts \(accepted.lowerBound)–\(accepted.upperBound) mg/dL.")
            case .empty, .valid:
                EmptyView()
            }
            Button("Continue") { flow.continueFromEntry(acceptedRange: range, now: now) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled({ if case .valid = parsed { return false } else { return true } }())
        }
    }

    /// The first value is not shown while retyping, so the second entry is read from the meter,
    /// not copied from the screen (review m4). It appears once both entries match.
    private func confirm(_ value: Int, takenAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("TYPE IT AGAIN")
            Text(verbatim: CalibrationRules.retypePrompt)
                .font(Typography.body(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            ValueField(label: "FINGERSTICK AGAIN, MG/DL", text: $flow.confirmText)
            if flow.confirmMismatch {
                FieldMessage(text: CalibrationRules.mismatchMessage)
            }
            if flow.showsValueForReview {
                FingerstickFigure(value: value, takenAt: takenAt)
            }
            Button("Confirm") {
                if let request = flow.continueFromConfirm(latest: state.latestLiveReading, sensorState: state.sensorState, now: now) {
                    submit(request)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!CalibrationRules.retypeMatches(value, retyped: flow.confirmText))
            Button("Start over") { flow.startOver() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func largeDifference(_ value: Int, difference: CalibrationDifference) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: "Are you sure?")
                .font(Typography.title(size: 32))
                .foregroundStyle(Theme.alert)
            Text(verbatim: CalibrationRules.largeDifferenceMessage(difference, fingerstick: value) ?? "")
                .font(Typography.body(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            Button("Calibrate anyway") {
                if let request = flow.confirmLargeDifference() { submit(request) }
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Cancel") { flow.startOver() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func submitted(_ request: CalibrationRequest) -> some View {
        let outcome = state.lastSubmission.flatMap { $0.request.id == request.id ? $0.outcome : nil }
        let text: (title: String, detail: String) = outcome.map(CalibrationRules.outcomeText) ?? (title: "Sending", detail: "Handing the calibration to the sensor connection.")
        return VStack(alignment: .leading, spacing: 14) {
            FingerstickFigure(value: request.mgdl, takenAt: request.takenAt)
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(outcomeStyle(outcome)).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: text.title).font(Typography.body(size: 15, weight: .semibold))
                    Text(verbatim: text.detail).font(Typography.body(size: 14)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Button("Done", action: close).buttonStyle(PrimaryButtonStyle())
        }
    }

    private func outcomeStyle(_ outcome: CalibrationSubmission.Outcome?) -> AnyShapeStyle {
        switch outcome {
        case .status(.accepted): return AnyShapeStyle(Theme.accent)
        case .status(.rejected), .status(.unknown), .refused: return AnyShapeStyle(Theme.alert)
        case .status(.queued), .status(.sent), nil: return AnyShapeStyle(Theme.muted)
        }
    }

    /// "Sensor now: 105 mg/dL, steady, 3 min ago" for context; from the live reading only.
    private var sensorNow: String {
        guard case .current(let reading) = GlucoseDisplayState.classify(latest: state.latestLiveReading, sensorState: state.sensorState, now: now) else {
            return "NO CURRENT SENSOR READING TO COMPARE WITH"
        }
        let age = AgeText.upper(minutes: AgeText.wholeMinutes(from: reading.date, to: now))
        return "SENSOR NOW: \(GlucoseText.valueWithUnit(reading.value).uppercased()) · \(TrendText.word(reading.trend).uppercased()) · \(age)"
    }
}

/// The fingerstick value, large, labelled as a fingerstick with the time it was taken.
struct FingerstickFigure: View {
    let value: Int
    let takenAt: Date

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Text(verbatim: String(value))
                .font(Typography.statHero(size: 96))
                .lineLimit(1)
                .padding(.vertical, -10)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "mg/dL").font(Typography.label(size: 12))
                Text(verbatim: "FINGERSTICK").monoLabel(size: 10).foregroundStyle(Theme.muted)
                Text(verbatim: "taken \(TimeText.time(takenAt))").font(Typography.label(size: 11)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Fingerstick \(value) milligrams per deciliter, taken at \(TimeText.time(takenAt))"))
    }
}

struct ValueField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label).monoLabel(size: 10).foregroundStyle(Theme.muted)
            TextField(text: Binding(get: { text }, set: { text = String($0.filter { $0.isASCII && $0.isNumber }.prefix(3)) })) {
                Text(verbatim: "—")
            }
            .keyboardType(.numberPad)
            .font(Typography.figure(size: 36))
            .frame(minHeight: 56)
            .padding(.horizontal, 12)
            .overlay(Rectangle().stroke(Theme.ink, lineWidth: 1))
            .accessibilityLabel(Text(verbatim: label.lowercased()))
        }
    }
}

struct FieldMessage: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Typography.body(size: 13, weight: .medium))
            .foregroundStyle(Theme.alert)
            .fixedSize(horizontal: false, vertical: true)
    }
}
