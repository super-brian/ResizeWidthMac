import AppKit

enum ScreenGeometry {
    private static let tolerance: CGFloat = 16
    /// Displays count as neighbors for span only if edges are nearly flush.
    private static let maxSpanGap: CGFloat = 48
    /// Span neighbor must match display height within this many points.
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

    static func screenContaining(cocoaRect: CGRect) -> NSScreen? {
        screenContaining(point: CGPoint(x: cocoaRect.midX, y: cocoaRect.midY))
    }

    /// For span-right, anchor on the window's left edge; for span-left, the right edge.
    /// Avoids re-homing onto the middle display after a full two-monitor span.
    static func homeScreenForSpan(windowRect: CGRect, extendRight: Bool) -> NSScreen? {
        let edgeX = extendRight ? windowRect.minX + 2 : windowRect.maxX - 2
        let point = CGPoint(x: edgeX, y: windowRect.midY)
        return screenContaining(point: point)
    }

    static func maximizeRect(on screen: NSScreen) -> CGRect {
        screen.visibleFrame
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
        bestAdjacent(to: home, extendRight: extendRight, requireMatchingSpan: false)
    }

    /// Adjacent screen suitable for span: nearly flush edges + same display height.
    /// Skips e.g. a landscape laptop beside two matched portrait monitors.
    static func adjacentMatchingScreen(to home: NSScreen, extendRight: Bool) -> NSScreen? {
        bestAdjacent(to: home, extendRight: extendRight, requireMatchingSpan: true)
    }

    private static func bestAdjacent(
        to home: NSScreen,
        extendRight: Bool,
        requireMatchingSpan: Bool
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

            if requireMatchingSpan {
                if abs(candidate.height - current.height) > maxHeightDelta {
                    continue
                }
                if gap > maxSpanGap {
                    continue
                }
            }

            let overlap = axisOverlap(
                current.minY, current.maxY,
                candidate.minY, candidate.maxY
            )
            let gapInt = Int(gap)

            if best == nil || overlap > bestOverlap || (overlap == bestOverlap && gapInt < bestGap) {
                best = screen
                bestOverlap = overlap
                bestGap = gapInt
            }
        }
        return best
    }

    private static func axisOverlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Int {
        let start = max(a0, b0)
        let end = min(a1, b1)
        return Int(max(0, end - start))
    }
}
