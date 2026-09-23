// App entry point. Phase 2 adds dependency wiring (G7Kit → GlucoseStore → UI, AlertEngine,
// TrioBridge, uploaders, widget snapshot) to AppModel.

import SwiftUI

@main
struct SensorApp: App {
    @State private var model = AppModel.launch()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { model.open($0) }
        }
    }
}
