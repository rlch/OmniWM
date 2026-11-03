// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

final class NiriEdgeOutsetTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 700)

    func testEdgesOnTheWorkingFrameGrowPastIt() {
        let outset = NiriEdgeOutset(points: 1, bounds: bounds, gapX: 0, gapY: 0)
        // The left column: past the left, top and bottom edges, and 1 pt into the next column.
        XCTAssertEqual(
            outset.apply(CGRect(x: 0, y: 0, width: 500, height: 700)),
            CGRect(x: -1, y: -1, width: 502, height: 702)
        )
        // The right column: past the right, top and bottom edges; its left edge is the seam, left as it is.
        XCTAssertEqual(
            outset.apply(CGRect(x: 500, y: 0, width: 500, height: 700)),
            CGRect(x: 500, y: -1, width: 501, height: 702)
        )
    }

    func testWindowsStackedInAColumnOverlapAtTheirSeam() {
        let outset = NiriEdgeOutset(points: 1, bounds: bounds, gapX: 0, gapY: 0)
        XCTAssertEqual(
            outset.apply(CGRect(x: 0, y: 0, width: 1_000, height: 350)),
            CGRect(x: -1, y: -1, width: 1_002, height: 352)
        )
        XCTAssertEqual(
            outset.apply(CGRect(x: 0, y: 350, width: 1_000, height: 350)),
            CGRect(x: -1, y: 350, width: 1_002, height: 351)
        )
    }

    func testWithGapsOnlyTheScreenEdgesGrow() {
        let outset = NiriEdgeOutset(points: 1, bounds: bounds, gapX: 10, gapY: 10)
        XCTAssertEqual(
            outset.apply(CGRect(x: 0, y: 0, width: 495, height: 700)),
            CGRect(x: -1, y: -1, width: 496, height: 702)
        )
        XCTAssertEqual(
            outset.apply(CGRect(x: 505, y: 10, width: 495, height: 680)),
            CGRect(x: 505, y: 10, width: 496, height: 680)
        )
    }

    func testZeroOrAWindowOffTheScreenIsLeftAsItIs() {
        let frame = CGRect(x: 0, y: 0, width: 500, height: 700)
        XCTAssertEqual(NiriEdgeOutset(points: 0, bounds: bounds, gapX: 0, gapY: 0).apply(frame), frame)
        XCTAssertEqual(NiriEdgeOutset.none.apply(frame), frame)
        let hidden = CGRect(x: 3_000, y: 0, width: 500, height: 700)
        XCTAssertEqual(NiriEdgeOutset(points: 1, bounds: bounds, gapX: 0, gapY: 0).apply(hidden), hidden)
    }

    func testTheOrientationPicksWhichGapIsWhich() {
        let vertical = NiriEdgeOutset(
            points: 1,
            workingFrame: bounds,
            primaryGap: 10,
            secondaryGap: 0,
            orientation: .vertical
        )
        XCTAssertEqual(vertical.gapX, 0)
        XCTAssertEqual(vertical.gapY, 10)
    }

    func testTheSettingDefaultsToZeroIsOptionalAndRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().niri.edgeOutset, 0)
        var export = SettingsExport.defaults()
        export.niri.edgeOutset = 1
        let toml = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        XCTAssertTrue(toml.contains("edgeOutset = 1"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(toml.utf8)).niri.edgeOutset, 1)
        let without = toml.components(separatedBy: "\n").filter { !$0.hasPrefix("edgeOutset") }
        XCTAssertNil(try SettingsTOMLCodec.decode(Data(without.joined(separator: "\n").utf8)).niri.edgeOutset)
    }
}
