import SwiftUI

@main
struct RaumfeldRemoteApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            // Stop polling volumes and playback state in the background.
            model.setActive(phase == .active)
        }
    }
}
