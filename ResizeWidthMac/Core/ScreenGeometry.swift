import AppKit

enum ScreenGeometry {
    private static let tolerance: CGFloat = 16
    /// Displays count as neighbors for span only if edges are nearly flush.
    private static let maxSpanGap: CGFloat = 48
    /// Twin neighbor must match width/height within this many points.
    private static let maxHeightDelta: CGFloat = 32

    /// Primary display's Cocoa maxY — used to flip between AX (top-left) and Cocoa (bottom-left).
    static var desktopTopY: CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.maxY
        }
        return NSScreen.main?.frame.maxY ?? 0
    }

    static func cocoaToAX(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: desktopTopY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func axToCocoa(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: desktopTopY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screenContaining(point: CGPoint) -> NSScreen? {
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return hit
        }
        return NSScreen.screens.min { a, b in
            hypot(a.frame.midX - point.x, a.frame.midY - point.y)
                < hypot(b.frame.midX - point.x, b.frame.midY - point.y)
        }
    }

    /// Prefer the display that contains the largest share of the window.
    /// If two (or more) are within 5% area, pick the leftmost.
    static func screenContaining(cocoaRect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let scored: [(screen: NSScreen, area: CGFloat)] = screens.map { screen in
            let overlap = cocoaRect.intersection(screen.frame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            return (screen, area)
        }

        let bestArea = scored.map(\.area).max() ?? 0
        if bestArea <= 0 {
            // No overlap — fall back to nearest center.
            return screenContaining(point: CGPoint(x: cocoaRect.midX, y: cocoaRect.midY))
        }

        let nearBest = scored.filter { entry in
            guard entry.area > 0 else { return false }
            return (bestArea - entry.area) / bestArea <= 0.05
        }

        return nearBest.min(by: { $0.screen.frame.minX < $1.screen.frame.minX })?.screen
            ?? scored.max(by: { $0.area < $1.area })?.screen
    }

    /// For span-right, anchor on the window's left edge; for span-left, the right edge.
    /// Avoids re-homing onto the middle display after a full two-monitor span.
    static func homeScreenForSpan(windowRect: CGRect, extendRight: Bool) -> NSScreen? {
        let edgeX = extendRight ? windowRect.minX + 2 : windowRect.maxX - 2
        let point = CGPoint(x: edgeX, y: windowRect.midY)
        return screenContaining(point: point)
    }

    /// Usable area that keeps the menu bar (and Dock) visible.
    /// Always clears the top menu-bar band — `visibleFrame` alone is not enough when
    /// the menu bar auto-hides, and accessory apps often report a 0 menu height.
    static func workFrame(on screen: NSScreen) -> CGRect {
        let full = screen.frame
        var work = screen.visibleFrame

        let topClearance = max(
            full.maxY - work.maxY,
            menuBarThickness(),
            minMenuBarClearance,
            screen.safeAreaInsets.top
        )
        let allowedMaxY = full.maxY - topClearance
        if work.maxY > allowedMaxY + 0.5 {
            work.size.height = max(0, work.size.height - (work.maxY - allowedMaxY))
        }
        return work
    }

    /// Vertical band shared by both screens so a span never covers either menu bar/Dock.
    static func jointWorkBand(home: NSScreen, adjacent: NSScreen) -> (minY: CGFloat, height: CGFloat) {
        let a = workFrame(on: home)
        let b = workFrame(on: adjacent)
        let minY = max(a.minY, b.minY)
        let maxY = min(a.maxY, b.maxY)
        return (minY, max(0, maxY - minY))
    }

    static func maximizeRect(on screen: NSScreen) -> CGRect {
        workFrame(on: screen)
    }

    static func isApproximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = tolerance) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance
            && abs(a.origin.y - b.origin.y) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    /// Screens ordered left-to-right (then bottom-to-top) for wrap-around cycling.
    static func screensInCycleOrder() -> [NSScreen] {
        NSScreen.screens.sorted { a, b in
            if abs(a.frame.minX - b.frame.minX) > 1 {
                return a.frame.minX < b.frame.minX
            }
            return a.frame.minY < b.frame.minY
        }
    }

    /// Next/previous display in arrangement order, wrapping at the ends.
    static func nextScreenInCycle(from home: NSScreen, moveRight: Bool) -> NSScreen? {
        let ordered = screensInCycleOrder()
        guard ordered.count > 1 else { return nil }

        let homeFrame = home.frame
        guard let index = ordered.firstIndex(where: {
            isApproximatelyEqual($0.frame, homeFrame, tolerance: 1)
        }) else {
            return nil
        }

        let count = ordered.count
        let nextIndex = moveRight
            ? (index + 1) % count
            : (index - 1 + count) % count
        return ordered[nextIndex]
    }

    /// Any adjacent screen on that side (used for move-between-displays).
    static func adjacentScreen(to home: NSScreen, extendRight: Bool) -> NSScreen? {
        bestAdjacent(to: home, extendRight: extendRight, matchMode: .any)
    }

    /// Twin neighbor for span: same size, same orientation, shared edge >95%.
    /// Skips e.g. a landscape laptop beside two matched portrait monitors.
    static func adjacentMatchingScreen(to home: NSScreen, extendRight: Bool) -> NSScreen? {
        adjacentTwinScreen(to: home, extendRight: extendRight)
    }

    /// Twin neighbor: same size, same orientation, flush edge sharing >95% of the edge.
    static func adjacentTwinScreen(to home: NSScreen, extendRight: Bool) -> NSScreen? {
        bestAdjacent(to: home, extendRight: extendRight, matchMode: .twin)
    }

    /// Best twin on either side. If both match, prefer the side the window already overlaps more.
    static func bestAdjacentTwin(to home: NSScreen, windowRect: CGRect) -> (screen: NSScreen, extendRight: Bool)? {
        let right = adjacentTwinScreen(to: home, extendRight: true)
        let left = adjacentTwinScreen(to: home, extendRight: false)

        switch (left, right) {
        case (nil, nil):
            return nil
        case (nil, let r?):
            return (r, true)
        case (let l?, nil):
            return (l, false)
        case (let l?, let r?):
            let areaR = overlapArea(windowRect, r.frame)
            let areaL = overlapArea(windowRect, l.frame)
            return areaR >= areaL ? (r, true) : (l, false)
        }
    }

    private enum AdjacentMatchMode {
        /// Any neighbor on that side.
        case any
        /// Same size, same orientation, shared edge >95%.
        case twin
    }

    private static let minSharedEdgeFraction: CGFloat = 0.95

    private static func bestAdjacent(
        to home: NSScreen,
        extendRight: Bool,
        matchMode: AdjacentMatchMode
    ) -> NSScreen? {
        let current = home.frame
        var best: NSScreen?
        var bestOverlap = -1
        var bestGap = Int.max

        for screen in NSScreen.screens {
            let candidate = screen.frame
            if isApproximatelyEqual(candidate, current, tolerance: 1) {
                continue
            }

            let onSide = extendRight
                ? candidate.minX >= current.maxX - 1
                : candidate.maxX <= current.minX + 1
            if !onSide { continue }

            let gap = extendRight
                ? candidate.minX - current.maxX
                : current.minX - candidate.maxX
            if gap < -1 {
                continue
            }

            let overlap = axisOverlap(
                current.minY, current.maxY,
                candidate.minY, candidate.maxY
            )

            switch matchMode {
            case .any:
                break
            case .twin:
                if abs(candidate.width - current.width) > maxHeightDelta {
                    continue
                }
                if abs(candidate.height - current.height) > maxHeightDelta {
                    continue
                }
                let homeLandscape = current.width >= current.height
                let candLandscape = candidate.width >= candidate.height
                if homeLandscape != candLandscape {
                    continue
                }
                if gap > maxSpanGap {
                    continue
                }
                let edgeLen = min(current.height, candidate.height)
                if edgeLen <= 0 || CGFloat(overlap) / edgeLen < minSharedEdgeFraction {
                    continue
                }
            }

            let gapInt = Int(gap)

            if best == nil || overlap > bestOverlap || (overlap == bestOverlap && gapInt < bestGap) {
                best = screen
                bestOverlap = overlap
                bestGap = gapInt
            }
        }
        return best
    }

    private static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private static func axisOverlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Int {
        let start = max(a0, b0)
        let end = min(a1, b1)
        return Int(max(0, end - start))
    }

    /// Fallback when this process has no normal app menu (LSUIElement / MenuBarExtra).
    private static let minMenuBarClearance: CGFloat = 25

    private static func menuBarThickness() -> CGFloat {
        let fromMenu = NSApp.mainMenu?.menuBarHeight ?? 0
        let fromStatus = NSStatusBar.system.thickness
        return max(fromMenu, fromStatus, minMenuBarClearance)
    }
}
