import AppKit
import ApplicationServices

enum SnapAction {
    case verticalUp
    case verticalDown
    case spanRight
    case spanLeft
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
            snapVertical(window: window, current: current, screen: screen, snapTop: true)
        case .verticalDown:
            snapVertical(window: window, current: current, screen: screen, snapTop: false)
        case .spanRight:
            span(window: window, current: current, extendRight: true)
        case .spanLeft:
            span(window: window, current: current, extendRight: false)
        case .moveDisplayRight:
            moveToAdjacentDisplay(window: window, current: current, screen: screen, moveRight: true)
        case .moveDisplayLeft:
            moveToAdjacentDisplay(window: window, current: current, screen: screen, moveRight: false)
        }
    }

    // MARK: - Vertical (Win+Up / Win+Down)

    private func snapVertical(window: AXUIElement, current: CGRect, screen: NSScreen, snapTop: Bool) {
        let work = screen.visibleFrame
        let workH = work.height
        let halfH = workH / 2
        let twoThirdsH = workH * 2 / 3
        let isMaximized = ScreenGeometry.isApproximatelyEqual(current, work, tolerance: tolerance)

        if snapTop {
            // max -> top 2/3 -> top 50% -> max -> ...
            if isMaximized {
                let rect = CGRect(
                    x: work.minX,
                    y: work.maxY - twoThirdsH,
                    width: work.width,
                    height: twoThirdsH
                )
                _ = WindowAccessor.setFrame(rect, of: window)
                return
            }

            let topAligned = abs(current.maxY - work.maxY) <= tolerance
            let isTopTwoThirds = topAligned && abs(current.height - twoThirdsH) <= tolerance

            if isTopTwoThirds {
                let rect = CGRect(
                    x: work.minX,
                    y: work.maxY - halfH,
                    width: work.width,
                    height: halfH
                )
                _ = WindowAccessor.setFrame(rect, of: window)
            } else {
                // From top half or anything else -> maximize
                _ = WindowAccessor.setFrame(work, of: window)
            }
            return
        }

        // max -> bottom 2/3 -> bottom 50% -> max -> ...
        if isMaximized {
            let rect = CGRect(
                x: work.minX,
                y: work.minY,
                width: work.width,
                height: twoThirdsH
            )
            _ = WindowAccessor.setFrame(rect, of: window)
            return
        }

        let bottomAligned = abs(current.minY - work.minY) <= tolerance
        let isBottomTwoThirds = bottomAligned && abs(current.height - twoThirdsH) <= tolerance

        if isBottomTwoThirds {
            let rect = CGRect(
                x: work.minX,
                y: work.minY,
                width: work.width,
                height: halfH
            )
            _ = WindowAccessor.setFrame(rect, of: window)
        } else {
            _ = WindowAccessor.setFrame(work, of: window)
        }
    }

    // MARK: - Span across nearby display

    private func span(window: AXUIElement, current: CGRect, extendRight: Bool) {
        // Anchor on the leading edge so a full two-monitor span does not re-home
        // onto the middle display and then spill into a mismatched laptop screen.
        guard let screen = ScreenGeometry.homeScreenForSpan(windowRect: current, extendRight: extendRight),
              let adjacent = ScreenGeometry.adjacentMatchingScreen(to: screen, extendRight: extendRight) else {
            return
        }

        let mon = screen.frame
        let work = screen.visibleFrame
        let monW = mon.width
        let adjMonW = adjacent.frame.width

        let expectedFullW = monW + adjMonW
        let isFull: Bool
        if extendRight {
            isFull = abs(current.minX - mon.minX) <= tolerance
                && abs(current.maxY - work.maxY) <= tolerance
                && abs(current.width - expectedFullW) <= tolerance
                && abs(current.height - work.height) <= tolerance
        } else {
            let expectedFullL = mon.minX - adjMonW
            isFull = abs(current.minX - expectedFullL) <= tolerance
                && abs(current.maxY - work.maxY) <= tolerance
                && abs(current.width - expectedFullW) <= tolerance
                && abs(current.height - work.height) <= tolerance
        }

        let reducedPercent: CGFloat = extendRight ? 80 : 50
        let percentOfAdj: CGFloat = isFull ? reducedPercent : 100
        let extend = adjMonW * percentOfAdj / 100

        let width = monW + extend
        let height = work.height
        let originY = work.maxY - height
        let originX = extendRight ? mon.minX : (mon.minX - extend)

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

        let src = screen.visibleFrame
        let dst = destination.visibleFrame

        // If maximized (or nearly filling work area), fill the destination work area.
        if ScreenGeometry.isApproximatelyEqual(current, src, tolerance: tolerance) {
            _ = WindowAccessor.setFrame(dst, of: window)
            return
        }

        let width = min(current.width, dst.width)
        let height = min(current.height, dst.height)

        // Keep relative position within the work area when possible.
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
