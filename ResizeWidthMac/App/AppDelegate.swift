import AppKit
import CoreServices
import ServiceManagement
import SwiftUI

enum LaunchAtLogin {
    private static let bootstrappedKey = "LaunchAtLogin.bootstrapped"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// First run only: register so the app comes back after restart.
    static func bootstrapIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: bootstrappedKey) else { return }
        UserDefaults.standard.set(true, forKey: bootstrappedKey)
        guard SMAppService.mainApp.status == .notRegistered else { return }
        try? SMAppService.mainApp.register()
    }

    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let props = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else {
            return false
        }
        return props.enumCodeValue == AEEventID(keyAELaunchedAsLogInItem)
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

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
        LaunchAtLogin.bootstrapIfNeeded()
        permissionState.refresh()
        hotkeyManager.onAction = { [weak self] action in
            Task { @MainActor in
                self?.handle(action)
            }
        }
        hotkeyManager.registerDefaults()

        // Login launch: stay in Dock with hotkeys, don't steal focus.
        if LaunchAtLogin.launchedAsLoginItem {
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    window.orderOut(nil)
                }
            }
            return
        }

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
