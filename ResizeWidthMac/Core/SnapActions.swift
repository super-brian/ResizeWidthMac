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
    /// ⌥⌘←/→ cycle: 50% → 75% → ⅓ → 50%…
    private let sideWidthPercents: [CGFloat] = [50, 75, 100.0 / 3.0]
    /// ⇧⌃↑ height cycle: full → 50% → ⅓ → full…
    private let verticalUpHeightPercents: [CGFloat] = [100, 50, 100.0 / 3.0]
    /// ⇧⌃↓ height cycle: 50% → 75% → ⅓ → 50%…
    private let verticalDownHeightPercents: [CGFloat] = [50, 75, 100.0 / 3.0]
    /// ⇧⌥⌘↑/↓ height cycle: 50% → 75% → ⅓ → 50%…
    private let spanHalfHeightPercents: [CGFloat] = [50, 75, 100.0 / 3.0]

    /// Per-window live frames after AX clamp (menu bar / Dock).
    private var lastFullSpanFrameRight: [WindowKey: CGRect] = [:]
    private var lastFullSpanFrameLeft: [WindowKey: CGRect] = [:]
    private var lastVerticalFramesTop: [WindowKey: [Int: CGRect]] = [:]
    private var lastVerticalFramesBottom: [WindowKey: [Int: CGRect]] = [:]
    private var lastSideFramesLeft: [WindowKey: [Int: CGRect]] = [:]
    private var lastSideFramesRight: [WindowKey: [Int: CGRect]] = [:]
    private var lastSpanHalfFramesTop: [WindowKey: [Int: CGRect]] = [:]
    private var lastSpanHalfFramesBottom: [WindowKey: [Int: CGRect]] = [:]

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

    // MARK: - Vertical (single display height cycle)

    /// ⇧⌃↑ — work-area top/full; cycle full → 50% → ⅓ → full…
    private func snapVerticalUp(window: AXUIElement, current: CGRect, screen: NSScreen) {
        snapVerticalSide(
            window: window,
            current: current,
            screen: screen,
            occupyTop: true,
            percents: verticalUpHeightPercents
        )
    }

    /// ⇧⌃↓ — work-area bottom; cycle height 50% → 75% → ⅓ → 50%…
    private func snapVerticalDown(window: AXUIElement, current: CGRect, screen: NSScreen) {
        snapVerticalSide(
            window: window,
            current: current,
            screen: screen,
            occupyTop: false,
            percents: verticalDownHeightPercents
        )
    }

    private func snapVerticalSide(
        window: AXUIElement,
        current: CGRect,
        screen: NSScreen,
        occupyTop: Bool,
        percents: [CGFloat]
    ) {
        let work = ScreenGeometry.workFrame(on: screen)
        let key = WindowAccessor.windowKey(of: window)
        let saved = savedStepFrames(
            key: key,
            topMap: &lastVerticalFramesTop,
            bottomMap: &lastVerticalFramesBottom,
            occupyTop: occupyTop
        )

        let currentIndex = detectVerticalStep(
            current: current,
            work: work,
            screen: screen,
            occupyTop: occupyTop,
            percents: percents,
            saved: saved
        )

        let nextIndex = currentIndex.map { ($0 + 1) % percents.count } ?? 0
        let next = verticalRect(on: work, percent: percents[nextIndex], occupyTop: occupyTop)
        _ = WindowAccessor.setFrame(next, of: window)
        storeStepFrame(
            window: window,
            key: key,
            index: nextIndex,
            topMap: &lastVerticalFramesTop,
            bottomMap: &lastVerticalFramesBottom,
            occupyTop: occupyTop
        )
    }

    private func verticalRect(on work: CGRect, percent: CGFloat, occupyTop: Bool) -> CGRect {
        let height = work.height * percent / 100
        let originY = occupyTop ? (work.maxY - height) : work.minY
        return CGRect(x: work.minX, y: originY, width: work.width, height: height)
    }

    /// Match ideal/saved rects, then fuzzy top/bottom height steps (AX often misses exact workFrame).
    private func detectVerticalStep(
        current: CGRect,
        work: CGRect,
        screen: NSScreen,
        occupyTop: Bool,
        percents: [CGFloat],
        saved: [Int: CGRect]
    ) -> Int? {
        for (index, percent) in percents.enumerated() {
            let candidate = verticalRect(on: work, percent: percent, occupyTop: occupyTop)
            if matches(current, ideal: candidate, saved: saved[index]) {
                return index
            }
        }

        let tol: CGFloat = 28
        let full = screen.frame

        // Nearly maximized → treat as the 100% step so the next press advances to 50%.
        if let fullIdx = percents.firstIndex(where: { abs($0 - 100) < 0.01 }) {
            let coversWork = current.width >= work.width - tol
                && current.height >= work.height - tol
                && current.minX <= work.minX + tol
                && current.maxX >= work.maxX - tol
            let coversScreen = current.width >= full.width - tol
                && current.height >= full.height - tol
            if coversWork || coversScreen
                || ScreenGeometry.isApproximatelyEqual(current, work, tolerance: tol)
                || ScreenGeometry.isApproximatelyEqual(current, full, tolerance: tol) {
                return fullIdx
            }
        }

        let widthOK = abs(current.width - work.width) <= tol
            || abs(current.width - full.width) <= tol
        let topAligned = abs(current.maxY - work.maxY) <= tol
            || abs(current.maxY - full.maxY) <= tol
        let bottomAligned = abs(current.minY - work.minY) <= tol
            || abs(current.minY - full.minY) <= tol
        guard widthOK, occupyTop ? topAligned : bottomAligned else { return nil }

        for (index, percent) in percents.enumerated() where abs(percent - 100) >= 0.01 {
            let expectedH = work.height * percent / 100
            if abs(current.height - expectedH) <= tol {
                return index
            }
        }
        return nil
    }

    // MARK: - Horizontal side cycle (50% → 75% → ⅓)

    /// ⌥⌘←/→ — pin to left/right edge of work area; cycle width 50% → 75% → ⅓ → 50%…
    private func snapHorizontalSide(
        window: AXUIElement,
        current: CGRect,
        screen: NSScreen,
        toLeft: Bool
    ) {
        let work = ScreenGeometry.workFrame(on: screen)
        let key = WindowAccessor.windowKey(of: window)
        let saved: [Int: CGRect]
        if let key {
            saved = (toLeft ? lastSideFramesLeft[key] : lastSideFramesRight[key]) ?? [:]
        } else {
            saved = [:]
        }

        var currentIndex: Int?
        for (index, percent) in sideWidthPercents.enumerated() {
            let candidate = sideRect(on: work, percent: percent, toLeft: toLeft)
            if matches(current, ideal: candidate, saved: saved[index]) {
                currentIndex = index
                break
            }
        }

        let nextIndex = currentIndex.map { ($0 + 1) % sideWidthPercents.count } ?? 0
        let next = sideRect(on: work, percent: sideWidthPercents[nextIndex], toLeft: toLeft)
        _ = WindowAccessor.setFrame(next, of: window)

        if let key, let actual = WindowAccessor.frame(of: window) {
            if toLeft {
                var map = lastSideFramesLeft[key] ?? [:]
                map[nextIndex] = actual
                lastSideFramesLeft[key] = map
            } else {
                var map = lastSideFramesRight[key] ?? [:]
                map[nextIndex] = actual
                lastSideFramesRight[key] = map
            }
        }
    }

    private func sideRect(on work: CGRect, percent: CGFloat, toLeft: Bool) -> CGRect {
        let width = work.width * percent / 100
        let originX = toLeft ? work.minX : (work.maxX - width)
        return CGRect(x: originX, y: work.minY, width: width, height: work.height)
    }

    // MARK: - Span across nearby display (full work height)

    private func span(window: AXUIElement, current: CGRect, extendRight: Bool) {
        // Anchor on the leading edge so a full two-monitor span does not re-home
        // onto the middle display and then spill into a mismatched laptop screen.
        guard let screen = ScreenGeometry.homeScreenForSpan(windowRect: current, extendRight: extendRight),
              let adjacent = ScreenGeometry.adjacentTwinScreen(to: screen, extendRight: extendRight) else {
            return
        }

        let mon = screen.frame
        let monW = mon.width
        let adjMonW = adjacent.frame.width
        let band = ScreenGeometry.jointWorkBand(home: screen, adjacent: adjacent)
        let height = band.height
        let originY = band.minY

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

        let key = WindowAccessor.windowKey(of: window)
        let savedFull: CGRect?
        if let key {
            savedFull = extendRight ? lastFullSpanFrameRight[key] : lastFullSpanFrameLeft[key]
        } else {
            savedFull = nil
        }
        let matchesSavedFull = savedFull.map {
            ScreenGeometry.isApproximatelyEqual(current, $0, tolerance: tolerance)
        } ?? false
        let isFull = matchesIdealFull || matchesSavedFull

        // Second press shrinks into the adjacent display (right 80%, left 50%).
        let reducedPercent: CGFloat = extendRight ? 80 : 50
        let percentOfAdj: CGFloat = isFull ? reducedPercent : 100
        let extend = adjMonW * percentOfAdj / 100

        let width = monW + extend
        let originX = extendRight ? mon.minX : (mon.minX - extend)

        let rect = CGRect(x: originX, y: originY, width: width, height: height)
        _ = WindowAccessor.setFrame(rect, of: window)

        if percentOfAdj == 100, let key, let actual = WindowAccessor.frame(of: window) {
            if extendRight {
                lastFullSpanFrameRight[key] = actual
            } else {
                lastFullSpanFrameLeft[key] = actual
            }
        }
    }

    // MARK: - Span twin display at top/bottom (height cycle)

    /// ⇧⌥⌘↑/↓ — twin span at top/bottom of joint work band; cycle 50% → 75% → ⅓ → 50%…
    private func spanHalf(window: AXUIElement, current: CGRect, occupyTop: Bool) {
        guard let screen = ScreenGeometry.screenContaining(cocoaRect: current),
              let match = ScreenGeometry.bestAdjacentTwin(to: screen, windowRect: current) else {
            return
        }

        let mon = screen.frame
        let adjW = match.screen.frame.width
        let width = mon.width + adjW
        let originX = match.extendRight ? mon.minX : (mon.minX - adjW)
        let band = ScreenGeometry.jointWorkBand(home: screen, adjacent: match.screen)
        let key = WindowAccessor.windowKey(of: window)
        let saved = savedStepFrames(
            key: key,
            topMap: &lastSpanHalfFramesTop,
            bottomMap: &lastSpanHalfFramesBottom,
            occupyTop: occupyTop
        )

        var currentIndex: Int?
        for (index, percent) in spanHalfHeightPercents.enumerated() {
            let candidate = spanHalfRect(
                originX: originX,
                width: width,
                bandMinY: band.minY,
                bandHeight: band.height,
                percent: percent,
                occupyTop: occupyTop
            )
            if matches(current, ideal: candidate, saved: saved[index]) {
                currentIndex = index
                break
            }
        }

        let nextIndex = currentIndex.map { ($0 + 1) % spanHalfHeightPercents.count } ?? 0
        let next = spanHalfRect(
            originX: originX,
            width: width,
            bandMinY: band.minY,
            bandHeight: band.height,
            percent: spanHalfHeightPercents[nextIndex],
            occupyTop: occupyTop
        )
        _ = WindowAccessor.setFrame(next, of: window)
        storeStepFrame(
            window: window,
            key: key,
            index: nextIndex,
            topMap: &lastSpanHalfFramesTop,
            bottomMap: &lastSpanHalfFramesBottom,
            occupyTop: occupyTop
        )
    }

    private func spanHalfRect(
        originX: CGFloat,
        width: CGFloat,
        bandMinY: CGFloat,
        bandHeight: CGFloat,
        percent: CGFloat,
        occupyTop: Bool
    ) -> CGRect {
        let height = bandHeight * percent / 100
        let originY = occupyTop ? (bandMinY + bandHeight - height) : bandMinY
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    // MARK: - Cycle between displays (arrangement order, wraps)

    private func moveToAdjacentDisplay(
        window: AXUIElement,
        current: CGRect,
        screen: NSScreen,
        moveRight: Bool
    ) {
        guard let destination = ScreenGeometry.nextScreenInCycle(from: screen, moveRight: moveRight) else {
            return
        }

        let src = ScreenGeometry.workFrame(on: screen)
        let dst = ScreenGeometry.workFrame(on: destination)

        // If filling the work area (or nearly), fill the destination work area.
        if ScreenGeometry.isApproximatelyEqual(current, src, tolerance: tolerance) {
            _ = WindowAccessor.setFrame(dst, of: window)
            return
        }

        let width = min(current.width, dst.width)
        let height = min(current.height, dst.height)

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

    // MARK: - Cycle helpers

    private func matches(_ current: CGRect, ideal: CGRect, saved: CGRect?) -> Bool {
        if ScreenGeometry.isApproximatelyEqual(current, ideal, tolerance: tolerance) {
            return true
        }
        if let saved, ScreenGeometry.isApproximatelyEqual(current, saved, tolerance: tolerance) {
            return true
        }
        return false
    }

    private func savedStepFrames(
        key: WindowKey?,
        topMap: inout [WindowKey: [Int: CGRect]],
        bottomMap: inout [WindowKey: [Int: CGRect]],
        occupyTop: Bool
    ) -> [Int: CGRect] {
        guard let key else { return [:] }
        return (occupyTop ? topMap[key] : bottomMap[key]) ?? [:]
    }

    private func storeStepFrame(
        window: AXUIElement,
        key: WindowKey?,
        index: Int,
        topMap: inout [WindowKey: [Int: CGRect]],
        bottomMap: inout [WindowKey: [Int: CGRect]],
        occupyTop: Bool
    ) {
        guard let key, let actual = WindowAccessor.frame(of: window) else { return }
        if occupyTop {
            var map = topMap[key] ?? [:]
            map[index] = actual
            topMap[key] = map
        } else {
            var map = bottomMap[key] ?? [:]
            map[index] = actual
            bottomMap[key] = map
        }
    }
}
