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

/// Stable `/Applications` symlink created by the Xcode build post-action.
enum ApplicationsLaunch {
    static let applicationsAppPath = "/Applications/ResizeWidthMac.app"
    static let fromApplicationsArgument = "--from-applications-link"

    static var applicationsAppURL: URL {
        URL(fileURLWithPath: applicationsAppPath)
    }

    static var launchedFromApplicationsLink: Bool {
        CommandLine.arguments.contains(fromApplicationsArgument)
    }

    static var resolvedSymlinkTarget: URL? {
        let path = applicationsAppPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return nil
        }
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            return URL(fileURLWithPath: dest).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    static var thisBuildURL: URL {
        Bundle.main.bundleURL.resolvingSymlinksInPath()
    }

    static var symlinkPointsAtThisBuild: Bool {
        guard let target = resolvedSymlinkTarget else { return false }
        return target.path == thisBuildURL.path
    }

    /// Relaunch through the Applications symlink so Login Items use a stable path.
    /// Bundle paths resolve through the symlink to DerivedData, so we use a launch arg
    /// (and skip relaunch for login-item starts / Xcode DEBUG runs).
    @MainActor
    static func relaunchViaApplicationsIfNeeded() -> Bool {
        #if DEBUG
        // Keep the Xcode-launched process so the debugger stays attached.
        return false
        #else
        if launchedFromApplicationsLink || LaunchAtLogin.launchedAsLoginItem {
            return false
        }
        guard symlinkPointsAtThisBuild else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "-c",
            "sleep 0.45; /usr/bin/open '\(applicationsAppPath)' --args \(fromApplicationsArgument)"
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
            return true
        } catch {
            NSLog("ResizeWidthMac: failed to relaunch via Applications: %@", error.localizedDescription)
            return false
        }
        #endif
    }

    static var userFacingWarning: String? {
        if launchedFromApplicationsLink || LaunchAtLogin.launchedAsLoginItem {
            return nil
        }
        #if DEBUG
        if Bundle.main.bundlePath.contains("DerivedData")
            || Bundle.main.bundlePath.contains("/Build/Products/") {
            // Informational only — DEBUG does not auto-relaunch.
            if symlinkPointsAtThisBuild {
                return "Running from Xcode (debugger). /Applications/ResizeWidthMac.app still points at this build for Login Items."
            }
        }
        #endif
        if symlinkPointsAtThisBuild {
            return nil
        }
        if resolvedSymlinkTarget == nil {
            return "Missing /Applications/ResizeWidthMac.app symlink. Build the app once so Login Items can use a stable path."
        }
        return "/Applications/ResizeWidthMac.app points at a different build. Rebuild to refresh the symlink, then reopen from Applications."
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let activateExistingNotification = Notification.Name("com.local.ResizeWidthMac.activateExisting")

    let permissionState = PermissionState()
    private let hotkeyManager = HotkeyManager()
    private let snapActions = SnapActions()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ApplicationsLaunch.relaunchViaApplicationsIfNeeded() {
            return
        }

        // Prefer this Applications-linked instance over an older one still running.
        if ApplicationsLaunch.launchedFromApplicationsLink {
            terminateOtherInstances()
        } else if activateExistingInstanceIfNeeded() {
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
        guard let existing = otherInstances().first else { return false }

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

    private func terminateOtherInstances() {
        for app in otherInstances() {
            app.terminate()
        }
    }

    private func otherInstances() -> [NSRunningApplication] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != myPID
        }
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
}
