// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class AXOverflowStagingTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1024, height: 768)

    func testAWindowGrowingPastItsScreenMovesItsTrailingEdgeOffFirst() {
        let current = CGRect(x: 0, y: 10, width: 497, height: 700)
        let target = CGRect(x: 0, y: 10, width: 4000, height: 700)
        XCTAssertEqual(
            AXWindowService.overflowStaging(currentFrame: current, targetFrame: target, screens: [screen]),
            CGRect(x: 984, y: 10, width: 497, height: 700)
        )
    }

    func testAWindowGrowingPastTheScreensBottomMovesItsBottomEdgeOffFirst() {
        // The edge outset: 1 pt past the bottom (AppKit y 0) and the right.
        let current = CGRect(x: 512, y: 0, width: 512, height: 736)
        let target = CGRect(x: 512, y: -1, width: 513, height: 737)
        XCTAssertEqual(
            AXWindowService.overflowStaging(currentFrame: current, targetFrame: target, screens: [screen]),
            CGRect(x: 984, y: 40 - 736, width: 512, height: 736)
        )
        // Only the bottom.
        XCTAssertEqual(
            AXWindowService.overflowStaging(
                currentFrame: CGRect(x: 0, y: 0, width: 500, height: 736),
                targetFrame: CGRect(x: 0, y: -1, width: 500, height: 737),
                screens: [screen]
            ),
            CGRect(x: 0, y: 40 - 736, width: 500, height: 736)
        )
    }

    func testAnEdgePastTheScreenThatTheMoveBringsBackIsStagedToo() {
        // The right column becomes the only one: it moves to x -1 first, which brings its right edge on screen.
        let current = CGRect(x: 512, y: -1, width: 513, height: 737)
        let target = CGRect(x: -1, y: -1, width: 1026, height: 738)
        XCTAssertEqual(
            AXWindowService.overflowStaging(currentFrame: current, targetFrame: target, screens: [screen]),
            CGRect(x: 984, y: 40 - 737, width: 513, height: 737)
        )
    }

    func testNoStagingWhenTheEdgeIsAlreadyOffOrTheWindowFitsOrShrinks() {
        let screens = [screen]
        let wide = CGRect(x: 0, y: 10, width: 4000, height: 700)
        // Past the edge, and still past it where the move puts it: AX grows it as asked.
        XCTAssertNil(AXWindowService.overflowStaging(
            currentFrame: CGRect(x: 517, y: 10, width: 1100, height: 700), targetFrame: wide, screens: screens
        ))
        // Fits its screen.
        XCTAssertNil(AXWindowService.overflowStaging(
            currentFrame: CGRect(x: 0, y: 10, width: 400, height: 700),
            targetFrame: CGRect(x: 0, y: 10, width: 900, height: 700),
            screens: screens
        ))
        // Shrinks.
        XCTAssertNil(AXWindowService.overflowStaging(
            currentFrame: CGRect(x: 0, y: 10, width: 4000, height: 700),
            targetFrame: CGRect(x: 0, y: 10, width: 3000, height: 700),
            screens: screens
        ))
        XCTAssertNil(AXWindowService.overflowStaging(currentFrame: nil, targetFrame: wide, screens: screens))
    }
}
