import SwiftUI
import AppKit
import ApplicationServices

@MainActor
final class PermissionState: ObservableObject {
    @Published var isTrusted = false

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        } else {
            objectWillChange.send()
            isTrusted = trusted
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

    private let shortcuts: [(keys: String, meaning: String)] = [
        ("⇧⌃↑", "Full ↔ top ½"),
        ("⇧⌃↓", "Bottom ½"),
        ("⌥⌘←", "Left 50% → 75% → 33% → …"),
        ("⌥⌘→", "Right 50% → 75% → 33% → …"),
        ("⇧⌥⌘→", "Span into matching twin on the right (full height)"),
        ("⇧⌥⌘←", "Span into matching twin on the left (full height)"),
        ("⇧⌥⌘↑", "Span into matching twin (top ½)"),
        ("⇧⌥⌘↓", "Span into matching twin (bottom ½)"),
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
                Text("Still orange after enabling? Remove ResizeWidthMac with − in Accessibility, Clean Build Folder, Run, then toggle ON. Turn Spectacle off.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .topLeading)
        .onAppear { permissionState.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionState.refresh()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            permissionState.refresh()
        }
    }
}
