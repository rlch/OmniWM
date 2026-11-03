// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

/// Tiled windows grown past the edges they touch (`niri.edgeOutset`): macOS draws a 1 pt outline
/// around every window, which shows as a line where a window ends exactly on a screen or bar edge.
/// An edge on the working frame's edge grows that far past it, and with no gap between windows, an
/// edge that meets the next window's grows into it, so the seam overlaps by the same amount. It is
/// applied to the final window frames, after which column is visible and on which display has been
/// decided, so it never counts as running onto a neighbouring display.
struct NiriEdgeOutset {
    let points: CGFloat
    let bounds: CGRect
    /// The gaps between windows side by side and one above another.
    let gapX: CGFloat
    let gapY: CGFloat
    /// Other frames whose edges are the screen's or the bar's too: a lone window fills one of them
    /// (the fill or fullscreen frame), which a border clearance can leave apart from `bounds`.
    var otherBounds: [CGRect] = []

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
        otherBounds = [area.singleWindowFrame, area.borderSafeFillFrame, area.fullscreenLayoutFrame, area.viewFrame]
    }

    func apply(_ frame: CGRect) -> CGRect {
        guard points > 0, !frame.isEmpty, !bounds.isNull, frame.intersects(bounds) else { return frame }
        let all = [bounds] + otherBounds.filter { !$0.isNull && !$0.isEmpty }
        func on(_ value: CGFloat, _ edge: (CGRect) -> CGFloat) -> Bool {
            all.contains { abs(value - edge($0)) < 0.5 }
        }
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        if on(minX, \.minX) { minX -= points }
        if on(maxX, \.maxX) {
            maxX += points
        } else if gapX == 0, maxX < bounds.maxX {
            maxX += points
        }
        if on(minY, \.minY) { minY -= points }
        if on(maxY, \.maxY) {
            maxY += points
        } else if gapY == 0, maxY < bounds.maxY {
            maxY += points
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
