// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct OffsetTransition: Equatable {
    enum Kind: Equatable {
        case jump
        case spring(SpringConfig)
        case deceleration
    }

    var rebaseDelta: CGFloat = 0
    var kind: Kind?
}

/// A part of a window wider than the view to keep in view: `span` points from `offset`, measured
/// from the window's leading edge. Every pan to the window's column narrows to that part, until the
/// operator pans, focuses another column, or the column fits the view.
struct ViewportReveal: Equatable {
    var token: WindowToken
    var offset: CGFloat
    var span: CGFloat
    /// Its column was focused and panned to: a later pan to another column clears it.
    var shown = false

    func asks(_ other: ViewportReveal) -> Bool {
        token == other.token && offset == other.offset && span == other.span
    }
}

struct ViewportState: Equatable {
    var activeColumnIndex: Int = 0

    var viewOffset: CGFloat = 0.0

    var preservesGestureOffset = false

    var offsetTransition = OffsetTransition()

    var selectedNodeId: NodeId?

    var viewOffsetToRestore: CGFloat?

    var activatePrevColumnOnRemoval: CGFloat?

    var displayRefreshRate: Double = 60.0

    var reveal: ViewportReveal?
}

extension ViewportState {
    var hasPendingOffsetAnimation: Bool {
        switch offsetTransition.kind {
        case .spring,
             .deceleration: true
        default: false
        }
    }

    mutating func rebaseOffset(by delta: CGFloat) {
        viewOffset += delta
        offsetTransition.rebaseDelta += delta
    }

    mutating func jumpOffset(to offset: CGFloat) {
        offsetTransition.rebaseDelta += offset - viewOffset
        viewOffset = offset
        offsetTransition.kind = .jump
    }

    mutating func springOffset(to offset: CGFloat, config: SpringConfig? = nil) {
        viewOffset = offset
        offsetTransition.kind = .spring(config ?? .niriHorizontalViewMovement)
    }

    mutating func decelerateOffset(to offset: CGFloat) {
        viewOffset = offset
        offsetTransition.kind = .deceleration
    }

    mutating func clearOffsetTransition() {
        offsetTransition = OffsetTransition()
    }
}
