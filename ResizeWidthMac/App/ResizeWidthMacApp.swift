import SwiftUI

@main
struct ResizeWidthMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu bar entry; preferences are an AppDelegate-owned window (avoids
        // showSettingsWindow: / SettingsLink warnings on newer macOS).
        MenuBarExtra("ResizeWidthMac", systemImage: "rectangle.split.2x1") {
            Button("Preferences…") {
                appDelegate.showPreferences()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit ResizeWidthMac") {
                appDelegate.quitApp()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
