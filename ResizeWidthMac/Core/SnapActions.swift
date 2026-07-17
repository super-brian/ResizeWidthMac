import AppKit
import ApplicationServices

enum SnapAction {
    case verticalUp
    case verticalDown
    case spanRight
    case spanLeft
    case spanHalfUp
    case spanHalfDown
    case moveDisplayRight
    case moveDisplayLeft
}

@MainActor
final class SnapActions {
    private let tolerance: CGFloat = 16

    func perform(_ action: SnapAction) {
        guard WindowAccessor.isTrusted(),
              let window = WindowAccessor.frontmostWindow(),
              let current = WindowAccessor.frame(of: window),
              let screen = ScreenGeometry.screenContaining(cocoaRect: current) else {
            return
        }

        switch action {
        case .verticalUp:
            snapVerticalUp(window: window, current: current, screen: screen)
        case .verticalDown:
            snapVerticalDown(window: window, current: current, screen: screen)
        case .spanRight:
            span(window: window, current: current, extendRight: true)
        case .spanLeft:
            span(window: window, current: current, extendRight: false)
        case .spanHalfUp:
            spanHalf(window: window, current: current, occupyTop: true)
        case .spanHalfDown:
            spanHalf(window: window, current: current, occupyTop: false)
        case .moveDisplayRight:
            moveToAdjacentDisplay(window: window, current: current, screen: screen, moveRight: true)
        case .moveDisplayLeft:
            moveToAdjacentDisplay(window: window, current: current, screen: screen, moveRight: false)
        }
    }

    // MARK: - Vertical

    /// ⇧⌃↑ — cycle full display ↔ top 50%.
    private func snapVerticalUp(window: AXUIElement, current: CGRect, screen: NSScreen) {
        let full = screen.frame
        let halfH = full.height / 2
        let isFull = ScreenGeometry.isApproximatelyEqual(current, full, tolerance: tolerance)
        let topHalf = CGRect(x: full.minX, y: full.maxY - halfH, width: full.width, height: halfH)
        let isTopHalf = ScreenGeometry.isApproximatelyEqual(current, topHalf, tolerance: tolerance)

        if isFull {
            _ = WindowAccessor.setFrame(topHalf, of: window)
        } else if isTopHalf {
            _ = WindowAccessor.setFrame(full, of: window)
        } else {
            _ = WindowAccessor.setFrame(full, of: window)
        }
    }

    /// ⇧⌃↓ — always bottom 50% (no cycle).
    private func snapVerticalDown(window: AXUIElement, current: CGRect, screen: NSScreen) {
        let full = screen.frame
        let halfH = full.height / 2
        let bottomHalf = CGRect(x: full.minX, y: full.minY, width: full.width, height: halfH)
        _ = WindowAccessor.setFrame(bottomHalf, of: window)
    }

    // MARK: - Span across nearby display (full height)

    private func span(window: AXUIElement, current: CGRect, extendRight: Bool) {
        // Anchor on the leading edge so a full two-monitor span does not re-home
        // onto the middle display and then spill into a mismatched laptop screen.
        guard let screen = ScreenGeometry.homeScreenForSpan(windowRect: current, extendRight: extendRight),
              let adjacent = ScreenGeometry.adjacentMatchingScreen(to: screen, extendRight: extendRight) else {
            return
        }

        let mon = screen.frame
        let monW = mon.width
        let adjMonW = adjacent.frame.width
        let height = mon.height
        let originY = mon.minY

        let expectedFullW = monW + adjMonW
        let isFull: Bool
        if extendRight {
            isFull = abs(current.minX - mon.minX) <= tolerance
                && abs(current.minY - originY) <= tolerance
                && abs(current.width - expectedFullW) <= tolerance
                && abs(current.height - height) <= tolerance
        } else {
            let expectedFullL = mon.minX - adjMonW
            isFull = abs(current.minX - expectedFullL) <= tolerance
                && abs(current.minY - originY) <= tolerance
                && abs(current.width - expectedFullW) <= tolerance
                && abs(current.height - height) <= tolerance
        }

        let reducedPercent: CGFloat = extendRight ? 80 : 50
        let percentOfAdj: CGFloat = isFull ? reducedPercent : 100
        let extend = adjMonW * percentOfAdj / 100

        let width = monW + extend
        let originX = extendRight ? mon.minX : (mon.minX - extend)

        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        _ = WindowAccessor.setFrame(rect, of: window)
    }

    // MARK: - Span twin display at top/bottom half

    /// ⇧⌥⌘↑/↓ — extend into a matching left/right twin display (same size & orientation,
    /// shared edge >95%) and occupy the top or bottom 50% of the combined span.
    private func spanHalf(window: AXUIElement, current: CGRect, occupyTop: Bool) {
        guard let screen = ScreenGeometry.screenContaining(cocoaRect: current),
              let match = ScreenGeometry.bestAdjacentTwin(to: screen, windowRect: current) else {
            return
        }

        let mon = screen.frame
        let adjW = match.screen.frame.width
        let width = mon.width + adjW
        let height = mon.height / 2
        let originX = match.extendRight ? mon.minX : (mon.minX - adjW)
        let originY = occupyTop ? (mon.maxY - height) : mon.minY

        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        _ = WindowAccessor.setFrame(rect, of: window)
    }

    // MARK: - Cycle between displays (Windows Win+Shift+Left/Right)

    private func moveToAdjacentDisplay(
        window: AXUIElement,
        current: CGRect,
        screen: NSScreen,
        moveRight: Bool
    ) {
        guard let destination = ScreenGeometry.nextScreenInCycle(from: screen, moveRight: moveRight) else {
            return
        }

        let src = screen.frame
        let dst = destination.frame

        // If maximized (or nearly filling the display), fill the destination display.
        if ScreenGeometry.isApproximatelyEqual(current, src, tolerance: tolerance) {
            _ = WindowAccessor.setFrame(dst, of: window)
            return
        }

        let width = min(current.width, dst.width)
        let height = min(current.height, dst.height)

        // Keep relative position within the display when possible.
        let relX: CGFloat
        if src.width > width {
            relX = (current.minX - src.minX) / (src.width - width)
        } else {
            relX = 0.5
        }
        let relY: CGFloat
        if src.height > height {
            relY = (current.minY - src.minY) / (src.height - height)
        } else {
            relY = 0.5
        }

        let clampedRelX = min(max(relX, 0), 1)
        let clampedRelY = min(max(relY, 0), 1)

        let originX = dst.minX + clampedRelX * (dst.width - width)
        let originY = dst.minY + clampedRelY * (dst.height - height)
        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        _ = WindowAccessor.setFrame(rect, of: window)
    }
}
