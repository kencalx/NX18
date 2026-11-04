import SwiftUI

@main
struct NintaniumBuilderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Nintanium Builder") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 660)
                .task { await model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Game…") { model.showAddGame = true }.keyboardShortcut("n")
            }
        }
        Settings {
            SettingsView().environment(model).frame(width: 620)
        }
    }
}
