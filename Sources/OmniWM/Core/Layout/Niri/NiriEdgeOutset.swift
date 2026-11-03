// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

/// Tiled windows grown past the edges they touch (`niri.edgeOutset`): macOS draws a 1 pt outline
/// around every window, which shows as a line where a window ends exactly on a screen or bar edge.
/// A left or right edge on the working frame's edge grows that far past it, and with no gap between windows, an
/// edge that meets the next window's grows into it, so the seam overlaps by the same amount. It is
/// applied to the final window frames, after which column is visible and on which display has been
/// decided, so it never counts as running onto a neighbouring display.
struct NiriEdgeOutset {
    let points: CGFloat
    let bounds: CGRect
    /// The gaps between windows side by side and one above another.
    let gapX: CGFloat
    let gapY: CGFloat

    static let none = NiriEdgeOutset(points: 0, bounds: .null, gapX: 0, gapY: 0)

    init(points: CGFloat, bounds: CGRect, gapX: CGFloat, gapY: CGFloat) {
        self.points = points
        self.bounds = bounds
        self.gapX = gapX
        self.gapY = gapY
    }

    init(
        points: CGFloat,
        area: WorkingAreaContext,
        primaryGap: CGFloat,
        secondaryGap: CGFloat,
        orientation: Monitor.Orientation
    ) {
        let horizontal = orientation == .horizontal
        self.init(
            points: points,
            bounds: area.workingFrame,
            gapX: horizontal ? primaryGap : secondaryGap,
            gapY: horizontal ? secondaryGap : primaryGap
        )
    }

    func apply(_ frame: CGRect) -> CGRect {
        guard points > 0, !frame.isEmpty, !bounds.isNull, frame.intersects(bounds) else { return frame }
        // An edge on or past the working frame's: a lone window fills a frame wider than the working
        // frame (ungapped fullscreen, or a border clearance), whose edges are the screen's.
        let tolerance: CGFloat = 0.5
        var minX = frame.minX, maxX = frame.maxX, maxY = frame.maxY
        let minY = frame.minY
        if minX <= bounds.minX + tolerance { minX -= points }
        if maxX >= bounds.maxX - tolerance {
            maxX += points
        } else if gapX == 0 {
            maxX += points
        }
        // Not past the top or bottom edge: macOS keeps a window's top at or below the menu bar and caps
        // its height at the screen's less the menu bar, so it would only be moved down and back.
        if maxY < bounds.maxY - tolerance, gapY == 0 { maxY += points }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
