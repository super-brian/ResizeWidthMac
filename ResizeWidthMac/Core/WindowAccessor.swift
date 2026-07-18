import AppKit
import ApplicationServices
import CoreGraphics

enum WindowAccessor {
    private static let axWindowNumberAttribute = "AXWindowNumber" as CFString

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Focused window of the frontmost *other* app (skips this process).
    /// If this app is frontmost, uses the topmost on-screen window from another app.
    static func frontmostWindow() -> AXUIElement? {
        let myPID = ProcessInfo.processInfo.processIdentifier

        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != myPID,
           let window = focusedWindow(ofPID: app.processIdentifier) ?? firstWindow(ofPID: app.processIdentifier) {
            return window
        }

        return frontmostForeignWindowFromWindowList(excluding: myPID)
    }

    static func windowKey(of window: AXUIElement) -> WindowKey? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return nil }
        // AXWindowNumber is missing on some apps — fall back to 0 so clamp memory still works per-process.
        let number = windowNumber(of: window) ?? 0
        return WindowKey(pid: pid, windowNumber: number)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = copyPoint(window, kAXPositionAttribute as CFString),
              let size = copySize(window, kAXSizeAttribute as CFString) else {
            return nil
        }
        // AX uses top-left origin; convert to Cocoa bottom-left for geometry math.
        return ScreenGeometry.axToCocoa(CGRect(origin: position, size: size))
    }

    static func setFrame(_ cocoaRect: CGRect, of window: AXUIElement) -> Bool {
        let axRect = ScreenGeometry.cocoaToAX(cocoaRect)
        let pos = axRect.origin
        let size = axRect.size

        var posValue = pos
        guard let posRef = AXValueCreate(.cgPoint, &posValue) else { return false }
        var sizeValue = size
        guard let sizeRef = AXValueCreate(.cgSize, &sizeValue) else { return false }

        // size → position → size → position: reliable when moving across displays
        // and for apps that clamp an intermediate frame.
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeRef)
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posRef)
        let sizeErr = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeRef)
        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posRef)
        return sizeErr == .success && posErr == .success
    }

    // MARK: - Private

    private static func focusedWindow(ofPID pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focused
        )
        if err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        return nil
    }

    private static func firstWindow(ofPID pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let winErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )
        if winErr == .success, let list = windowsRef as? [AXUIElement], let first = list.first {
            return first
        }
        return nil
    }

    private static func frontmostForeignWindowFromWindowList(excluding myPID: pid_t) -> AXUIElement? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID,
                  let windowID = entry[kCGWindowNumber as String] as? NSNumber else {
                continue
            }
            if let window = window(ofPID: ownerPID, number: CGWindowID(windowID.uint32Value)) {
                return window
            }
        }
        return nil
    }

    private static func window(ofPID pid: pid_t, number: CGWindowID) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
              let list = windowsRef as? [AXUIElement] else {
            return nil
        }
        return list.first { windowNumber(of: $0) == number }
    }

    private static func windowNumber(of window: AXUIElement) -> CGWindowID? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, axWindowNumberAttribute, &ref) == .success,
              let number = ref as? NSNumber else {
            return nil
        }
        return CGWindowID(number.uint32Value)
    }

    private static func copyPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
              let value = ref,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}

struct WindowKey: Hashable {
    let pid: pid_t
    let windowNumber: CGWindowID
}
