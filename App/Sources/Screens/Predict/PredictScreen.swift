// Predict tab (PROGRESS D56, D57): placeholder so the tab exists. The real screen (Zen Predict
// forecasts, labelled as predicted, never a reading) replaces this file in a later workstream.
// Shows no number of any kind (S1).

import SwiftUI
import WidgetCore

struct PredictScreen: View {
    var body: some View {
        ScrollView {
            PredictContent()
        }
        .editorialScreen()
    }
}

struct PredictContent: View {
    static let placeholder = "Forecasts from your Zen Predict model will appear here."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Predict")
                .font(Typography.title(size: 36))
                .accessibilityAddTraits(.isHeader)
            Hairline().padding(.top, 6)
            Text(verbatim: Self.placeholder)
                .font(Typography.body(size: 14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .accessibilityIdentifier("predict.placeholder")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.sideMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
    }
}
