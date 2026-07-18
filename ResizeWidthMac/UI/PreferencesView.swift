import SwiftUI
import AppKit
import ApplicationServices

@MainActor
final class PermissionState: ObservableObject {
    @Published var isTrusted = false
    @Published var applicationsLaunchWarning: String?

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        let warning = ApplicationsLaunch.userFacingWarning
        if warning != applicationsLaunchWarning {
            applicationsLaunchWarning = warning
        }
    }

    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject private var permissionState: PermissionState
    @State private var openAtLogin = LaunchAtLogin.isEnabled
    @State private var loginNeedsApproval = LaunchAtLogin.requiresApproval

    private let shortcuts: [(keys: String, meaning: String)] = [
        ("⇧⌃↑", "Full → 50% → ⅓ → …"),
        ("⇧⌃↓", "Bottom 50% → 75% → ⅓ → …"),
        ("⌥⌘←", "Left 50% → 75% → ⅓ → …"),
        ("⌥⌘→", "Right 50% → 75% → ⅓ → …"),
        ("⇧⌥⌘→", "Twin span right; again → 80% of right"),
        ("⇧⌥⌘←", "Twin span left; again → 50% of left"),
        ("⇧⌥⌘↑", "Twin span top 50% → 75% → ⅓ → …"),
        ("⇧⌥⌘↓", "Twin span bottom 50% → 75% → ⅓ → …"),
        ("⇧⌃→", "Cycle window to the next display"),
        ("⇧⌃←", "Cycle window to the previous display"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ResizeWidthMac")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Snap and span the frontmost window.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let warning = permissionState.applicationsLaunchWarning {
                Text(warning)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(shortcuts, id: \.keys) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.keys)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .frame(width: 64, alignment: .leading)
                        Text(row.meaning)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }

            Divider()

            Toggle("Open at Login", isOn: Binding(
                get: { openAtLogin },
                set: { newValue in
                    do {
                        try LaunchAtLogin.setEnabled(newValue)
                    } catch {
                        NSLog("ResizeWidthMac: launch-at-login error: %@", error.localizedDescription)
                    }
                    refreshLoginState()
                }
            ))
            .font(.system(size: 12))
            .toggleStyle(.switch)

            if loginNeedsApproval {
                HStack(spacing: 8) {
                    Text("Allow ResizeWidthMac in Login Items to start after restart.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Login Items") {
                        LaunchAtLogin.openLoginItemsSettings()
                    }
                }
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(permissionState.isTrusted ? Color.green.opacity(0.85) : Color.orange.opacity(0.9))
                    .frame(width: 8, height: 8)
                Text(permissionState.isTrusted
                     ? "Accessibility access granted"
                     : "Accessibility access required")
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }

            // Keep actions above help text so they are never clipped.
            HStack(spacing: 8) {
                if !permissionState.isTrusted {
                    Button("Grant Access…") {
                        permissionState.requestAccess()
                    }
                    Button("Open Settings") {
                        permissionState.openAccessibilitySettings()
                    }
                }
                Button("Recheck") {
                    permissionState.refresh()
                }
                Spacer(minLength: 0)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }

            if !permissionState.isTrusted {
                Text("Still orange after enabling? Remove ResizeWidthMac with − in Accessibility, rebuild, then toggle ON. Disable other window managers that use the same shortcuts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 400, alignment: .topLeading)
        .onAppear {
            permissionState.refresh()
            refreshLoginState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionState.refresh()
            refreshLoginState()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            // Poll only while waiting for Accessibility approval.
            if !permissionState.isTrusted {
                permissionState.refresh()
            }
        }
    }

    private func refreshLoginState() {
        openAtLogin = LaunchAtLogin.isEnabled
        loginNeedsApproval = LaunchAtLogin.requiresApproval
        permissionState.refresh()
    }
}
