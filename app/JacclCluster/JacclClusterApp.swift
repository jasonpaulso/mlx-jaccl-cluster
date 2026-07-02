import SwiftUI
import JacclClusterKit

@main
struct JacclClusterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(model: model)
        }
    }
}
