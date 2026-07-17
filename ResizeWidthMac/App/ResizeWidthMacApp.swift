import SwiftUI

@main
struct ResizeWidthMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Single window (not WindowGroup) so Cmd+N / reopen can't spawn duplicates.
        Window("ResizeWidthMac", id: "main") {
            PreferencesView()
                .environmentObject(appDelegate.permissionState)
        }
        .defaultSize(width: 400, height: 400)
    }
}
