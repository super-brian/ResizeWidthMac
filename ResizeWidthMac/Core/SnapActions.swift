import AppKit
import ApplicationServices

enum SnapAction {
    case verticalUp
    case verticalDown
    case spanRight
    case spanLeft
    case spanHalfUp
    case spanHalfDown
    case halfLeft
    case halfRight
    case moveDisplayRight
    case moveDisplayLeft
}

@MainActor
final class SnapActions {
    private let tolerance: CGFloat = 16
    /// ⌥⌘←/→ cycle: 50% → 75% → 33% → 50%…
    private let sideWidthPercents: [CGFloat] = [50, 75, 100.0 / 3.0]
    /// Live frame after the last 100% span (AX often clamps under the menu bar).
    private var lastFullSpanFrameRight: CGRect?
    private var lastFullSpanFrameLeft: CGRect?

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
        case .halfLeft:
            snapHorizontalSide(window: window, current: current, screen: screen, toLeft: true)
        case .halfRight:
            snapHorizontalSide(window: window, current: current, screen: screen, toLeft: false)
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

    // MARK: - Horizontal side cycle (50% → 75% → 33%)

    /// ⌥⌘←/→ — pin to left/right edge at full height; cycle width 50% → 75% → 33% → 50%…
    private func snapHorizontalSide(
        window: AXUIElement,
        current: CGRect,
        screen: NSScreen,
        toLeft: Bool
    ) {
        let full = screen.frame
        var currentIndex: Int?
        for (index, percent) in sideWidthPercents.enumerated() {
            let candidate = sideRect(on: full, percent: percent, toLeft: toLeft)
            if ScreenGeometry.isApproximatelyEqual(current, candidate, tolerance: tolerance) {
                currentIndex = index
                break
            }
        }

        let nextIndex = currentIndex.map { ($0 + 1) % sideWidthPercents.count } ?? 0
        let next = sideRect(on: full, percent: sideWidthPercents[nextIndex], toLeft: toLeft)
        _ = WindowAccessor.setFrame(next, of: window)
    }

    private func sideRect(on full: CGRect, percent: CGFloat, toLeft: Bool) -> CGRect {
        let width = full.width * percent / 100
        let originX = toLeft ? full.minX : (full.maxX - width)
        return CGRect(x: originX, y: full.minY, width: width, height: full.height)
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
        let matchesIdealFull: Bool
        if extendRight {
            matchesIdealFull = abs(current.minX - mon.minX) <= tolerance
                && abs(current.minY - originY) <= tolerance
                && abs(current.width - expectedFullW) <= tolerance
                && abs(current.height - height) <= tolerance
        } else {
            let expectedFullL = mon.minX - adjMonW
            matchesIdealFull = abs(current.minX - expectedFullL) <= tolerance
                && abs(current.minY - originY) <= tolerance
                && abs(current.width - expectedFullW) <= tolerance
                && abs(current.height - height) <= tolerance
        }

        // Prefer the last applied full frame — ideal geometry often misses menu-bar clamp.
        let savedFull = extendRight ? lastFullSpanFrameRight : lastFullSpanFrameLeft
        let matchesSavedFull = savedFull.map {
            ScreenGeometry.isApproximatelyEqual(current, $0, tolerance: tolerance)
        } ?? false
        let isFull = matchesIdealFull || matchesSavedFull

        let reducedPercent: CGFloat = extendRight ? 80 : 50
        let percentOfAdj: CGFloat = isFull ? reducedPercent : 100
        let extend = adjMonW * percentOfAdj / 100

        let width = monW + extend
        let originX = extendRight ? mon.minX : (mon.minX - extend)

        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        _ = WindowAccessor.setFrame(rect, of: window)

        if percentOfAdj == 100, let actual = WindowAccessor.frame(of: window) {
            if extendRight {
                lastFullSpanFrameRight = actual
            } else {
                lastFullSpanFrameLeft = actual
            }
        }
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
