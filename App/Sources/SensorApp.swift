// App entry point. The composition root (`AppEnvironment`) is created during launch by the app
// delegate and wires G7Kit → GlucoseStore → the reading pipeline → AlertEngine, TrioBridge,
// uploaders and the widget snapshot (docs/architecture.md). The UI reaches it through
// `AppEnvironment.shared.services` (`AppServices`).

import SwiftUI

@main
struct SensorApp: App {
    @UIApplicationDelegateAdaptor(SensorAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.launch()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            AppEnvironment.shared.scenePhaseChanged(to: phase)
        }
    }
}
