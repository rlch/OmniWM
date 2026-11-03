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

    func testNoStagingWhenTheEdgeIsAlreadyOffOrTheWindowFitsOrShrinks() {
        let screens = [screen]
        let wide = CGRect(x: 0, y: 10, width: 4000, height: 700)
        // Already past the edge: AX grows it as asked.
        XCTAssertNil(AXWindowService.overflowStaging(
            currentFrame: CGRect(x: 517, y: 10, width: 1024, height: 700), targetFrame: wide, screens: screens
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
