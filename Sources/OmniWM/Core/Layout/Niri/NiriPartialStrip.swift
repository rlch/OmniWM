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
    /// Notes the strip each window of a hidden column would take on its own display: every window of
    /// a column of stacked windows, the active one of a tabbed column. Its frame where it would be is
    /// its frame parked, moved back by as much as the column was. Noted whatever the setting says, so
    /// that an empty strip can say why (`PartialColumnPreviewController`).
    func notePartialStrips(
        _ projectedColumn: NiriProjectedColumn,
        parkedAt parked: CGRect,
        wouldBe rect: CGRect,
        pass: NiriColumnLayoutPass,
        frames: [WindowToken: CGRect]
    ) {
        let area = pass.context.area.workingFrame
        // The focused column is the operator's to move: no stand-in for it.
        guard let workspaceId = pass.workspaceId, !rect.intersection(area).isNull,
              !projectedColumn.windows.contains(where: { $0.id == pass.selectedNodeId })
        else { return }
        let windows: [NiriWindow] = if projectedColumn.column.isTabbed, projectedColumn.windows.count > 1 {
            projectedActiveWindow(in: projectedColumn).map { [$0] } ?? []
        } else {
            Array(projectedColumn.windows)
        }
        let dx = rect.minX - parked.minX
        let dy = rect.minY - parked.minY
        for window in windows where window.sizingMode == .normal {
            guard let frame = frames[window.token]?.offsetBy(dx: dx, dy: dy) else { continue }
            let strip = frame.intersection(area)
            guard !strip.isNull, strip.width >= 1, strip.height >= 1 else { continue }
            partialStrips[workspaceId, default: [:]][window.token] = NiriPartialStrip(frame: frame, strip: strip)
        }
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
