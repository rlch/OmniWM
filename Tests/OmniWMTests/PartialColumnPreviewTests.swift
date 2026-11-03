// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class PartialColumnPreviewTests: XCTestCase {
    private let workspace = WorkspaceDescriptor.ID()
    private let slack = WindowToken(pid: 1, windowId: 101)
    private let firefox = WindowToken(pid: 2, windowId: 202)
    private let strip = NiriPartialStrip(
        frame: CGRect(x: 1_829, y: 30, width: 910, height: 1_290),
        strip: CGRect(x: 2_056, y: 30, width: 683, height: 1_290)
    )

    private func controller(allowed: Bool = true, focused: @escaping @MainActor (WindowToken) -> Void = { _ in
    }) -> PartialColumnPreviewController {
        PartialColumnPreviewController(system: .init(
            captureAllowed: { allowed },
            handle: { _ in nil },
            window: { _ in nil },
            scale: { _ in 2 },
            focus: focused
        ))
    }

    func testTheStripIsTheWindowsRightPartFromItsTopLeft() {
        let unit = strip.unitRect
        XCTAssertEqual(unit.minX, 227.0 / 910, accuracy: 0.0001)
        XCTAssertEqual(unit.width, 683.0 / 910, accuracy: 0.0001)
        XCTAssertEqual(unit.minY, 0)
        XCTAssertEqual(unit.height, 1)
    }

    func testAPanelPerStripStaysThroughMotionAndGoesOnceItsColumnIsBackInView() {
        let previews = controller()
        previews.update(workspaceId: workspace, strips: [slack: strip, firefox: strip], active: true, settled: true)
        XCTAssertEqual(previews.shownTokens, [slack, firefox])
        // Moving: a strip missing from a frame of the motion keeps its panel and stream.
        previews.update(workspaceId: workspace, strips: [slack: strip], active: true, settled: false)
        XCTAssertEqual(previews.shownTokens, [slack, firefox])
        // Settled with Firefox's column back in view: its panel goes.
        previews.update(workspaceId: workspace, strips: [slack: strip], active: true, settled: true)
        XCTAssertEqual(previews.shownTokens, [slack])
        // Another workspace's update leaves this one's alone.
        previews.update(workspaceId: WorkspaceDescriptor.ID(), strips: [:], active: true, settled: true)
        XCTAssertEqual(previews.shownTokens, [slack])
    }

    func testTheWorkspaceNotShownOrTheSettingOffTakesItsPanels() {
        let previews = controller()
        previews.update(workspaceId: workspace, strips: [slack: strip], active: true, settled: true)
        previews.update(workspaceId: workspace, strips: [slack: strip], active: false, settled: false)
        XCTAssertEqual(previews.shownTokens, [])
    }

    func testWithoutScreenRecordingThereIsNoPanel() {
        let previews = controller(allowed: false)
        previews.update(workspaceId: workspace, strips: [slack: strip], active: true, settled: true)
        XCTAssertEqual(previews.shownTokens, [])
    }

    func testTheSettingIsOffByDefaultOptionalAndRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().niri.partialColumnPreview, false)
        var export = SettingsExport.defaults()
        export.niri.partialColumnPreview = true
        let toml = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        XCTAssertTrue(toml.contains("partialColumnPreview = true"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(toml.utf8)).niri.partialColumnPreview, true)
        let without = toml.components(separatedBy: "\n").filter { !$0.hasPrefix("partialColumnPreview") }
        XCTAssertNil(try SettingsTOMLCodec.decode(Data(without.joined(separator: "\n").utf8)).niri.partialColumnPreview)
    }
}
