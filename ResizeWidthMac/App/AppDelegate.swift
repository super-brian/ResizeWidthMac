import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let permissionState = PermissionState()
    private var prefsWindow: NSWindow?
    private let hotkeyManager = HotkeyManager()
    private let snapActions = SnapActions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        permissionState.refresh()
        hotkeyManager.onAction = { [weak self] action in
            Task { @MainActor in
                self?.handle(action)
            }
        }
        hotkeyManager.registerDefaults()
        showPreferences()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func handle(_ action: SnapAction) {
        permissionState.refresh()
        guard permissionState.isTrusted else {
            showPreferences()
            return
        }
        snapActions.perform(action)
    }

    @objc func showPreferences() {
        permissionState.refresh()

        if prefsWindow == nil {
            let root = PreferencesView()
                .environmentObject(permissionState)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "ResizeWidthMac"
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 400, height: 400))
            window.contentMinSize = NSSize(width: 380, height: 360)
            window.isReleasedWhenClosed = false
            window.center()
            prefsWindow = window
        } else {
            // Hosting controller keeps the old view if we only created once;
            // refresh size in case an older short window is still around.
            prefsWindow?.setContentSize(NSSize(width: 400, height: 400))
        }

        prefsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        hotkeyManager.unregisterAll()
        NSApp.terminate(nil)
    }
}
