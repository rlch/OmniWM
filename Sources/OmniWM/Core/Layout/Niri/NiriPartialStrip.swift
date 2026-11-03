// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

/// A column hidden because it would run onto a neighbouring display: where its window would be, and
/// the part of that on its own display, which `PartialColumnPreviewController` fills with a live view.
struct NiriPartialStrip: Equatable {
    let frame: CGRect
    let strip: CGRect

    /// The strip's part of the window, in unit coordinates from the window's top left.
    var unitRect: CGRect {
        guard frame.width > 0, frame.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(
            x: (strip.minX - frame.minX) / frame.width,
            y: (frame.maxY - strip.maxY) / frame.height,
            width: strip.width / frame.width,
            height: strip.height / frame.height
        )
    }
}

extension NiriLayoutEngine {
    /// Notes the strip a hidden column would take on its own display: one window shown, alone or the
    /// active tab; a column of stacked windows has no single view.
    func notePartialStrip(
        _ projectedColumn: NiriProjectedColumn,
        rect: CGRect,
        area: CGRect,
        pass: NiriColumnLayoutPass
    ) {
        guard partialColumnPreview, let workspaceId = pass.workspaceId,
              projectedColumn.windows.count == 1 || projectedColumn.column.isTabbed,
              let window = projectedActiveWindow(in: projectedColumn),
              window.sizingMode == .normal
        else { return }
        let strip = rect.intersection(area)
        guard !strip.isNull, strip.width >= 1, strip.height >= 1 else { return }
        partialStrips[workspaceId, default: [:]][window.token] = NiriPartialStrip(frame: rect, strip: strip)
    }
}

extension NiriLayoutEngine {
    /// The fork's display-edge settings: `partialColumnsAcrossDisplays`, `edgeOutset`, `partialColumnPreview`.
    func updateDisplayEdgeConfiguration(
        partialColumnsAcrossDisplays: Bool?,
        edgeOutset: CGFloat?,
        partialColumnPreview: Bool?
    ) {
        if let partialColumnsAcrossDisplays {
            self.partialColumnsAcrossDisplays = partialColumnsAcrossDisplays
        }
        if let edgeOutset {
            self.edgeOutset = edgeOutset.clamped(to: 0 ... 8)
        }
        if let partialColumnPreview {
            self.partialColumnPreview = partialColumnPreview
        }
    }
}
