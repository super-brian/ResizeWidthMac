import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let activateExistingNotification = Notification.Name("com.local.ResizeWidthMac.activateExisting")

    let permissionState = PermissionState()
    private let hotkeyManager = HotkeyManager()
    private let snapActions = SnapActions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceIfNeeded() {
            return
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActivateExistingNotification(_:)),
            name: Self.activateExistingNotification,
            object: nil
        )

        NSApp.setActivationPolicy(.regular)
        permissionState.refresh()
        hotkeyManager.onAction = { [weak self] action in
            Task { @MainActor in
                self?.handle(action)
            }
        }
        hotkeyManager.registerDefaults()

        // Do not create a second preferences window here — SwiftUI `Window` already owns it.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            Self.orderFrontMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        hotkeyManager.unregisterAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep hotkeys alive when the preferences window is closed; Dock icon stays.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreferences()
        return true
    }

    /// If another ResizeWidthMac is already running, activate it and quit this process.
    private func activateExistingInstanceIfNeeded() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier

        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != myPID
        }
        guard let existing = others.first else { return false }

        DistributedNotificationCenter.default().postNotificationName(
            Self.activateExistingNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        existing.activate(options: [.activateIgnoringOtherApps])
        NSApp.terminate(nil)
        return true
    }

    @objc private func handleActivateExistingNotification(_ notification: Notification) {
        showPreferences()
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
        NSApp.activate(ignoringOtherApps: true)
        Self.orderFrontMainWindow()
    }

    /// Bring the SwiftUI main window forward if it exists.
    private static func orderFrontMainWindow() {
        let candidates = NSApp.windows.filter { window in
            window.canBecomeKey || window.canBecomeMain
        }
        guard let existing = candidates.first else { return }
        if existing.isMiniaturized {
            existing.deminiaturize(nil)
        }
        existing.makeKeyAndOrderFront(nil)
    }

    @objc func quitApp() {
        hotkeyManager.unregisterAll()
        NSApp.terminate(nil)
    }
}
