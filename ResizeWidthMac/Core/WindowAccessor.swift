import AppKit
import ApplicationServices

enum WindowAccessor {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Frontmost app's focused window, excluding our own process.
    static func frontmostWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focused
        )
        if err == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }

        // Fallback: first window
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
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeRef)
        _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posRef)
        return true
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
