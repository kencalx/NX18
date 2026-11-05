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
            CommandGroup(replacing: .newItem) {   // in place of New Window, which also takes Cmd-N and comes first: one window, whose model they all share
                Button("Add Game…") { model.showAddGame = true }.keyboardShortcut("n")
            }
        }
        Settings {
            SettingsView().environment(model).frame(width: 620)
        }
    }
}
