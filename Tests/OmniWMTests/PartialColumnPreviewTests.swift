// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import CoreVideo
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
        // Mid-animation: no panel made yet.
        previews.update(workspaceId: workspace, strips: [slack: strip], shown: true, enabled: true, settled: false)
        XCTAssertEqual(previews.shownTokens, [])
        previews.update(
            workspaceId: workspace,
            strips: [slack: strip, firefox: strip],
            shown: true,
            enabled: true,
            settled: true
        )
        XCTAssertEqual(previews.shownTokens, [slack, firefox])
        // Moving: a strip missing from a frame of the motion keeps its panel and stream.
        previews.update(workspaceId: workspace, strips: [slack: strip], shown: true, enabled: true, settled: false)
        XCTAssertEqual(previews.shownTokens, [slack, firefox])
        // Settled with Firefox's column back in view: its panel goes.
        previews.update(workspaceId: workspace, strips: [slack: strip], shown: true, enabled: true, settled: true)
        XCTAssertEqual(previews.shownTokens, [slack])
        // Another workspace's update leaves this one's alone.
        previews.update(workspaceId: WorkspaceDescriptor.ID(), strips: [:], shown: true, enabled: true, settled: true)
        XCTAssertEqual(previews.shownTokens, [slack])
    }

    func testTheWorkspaceNotShownOrTheSettingOffTakesItsPanels() {
        let previews = controller()
        previews.update(workspaceId: workspace, strips: [slack: strip], shown: true, enabled: true, settled: true)
        previews.update(workspaceId: workspace, strips: [slack: strip], shown: false, enabled: true, settled: false)
        XCTAssertEqual(previews.shownTokens, [])
        previews.update(workspaceId: workspace, strips: [slack: strip], shown: true, enabled: true, settled: true)
        previews.update(workspaceId: workspace, strips: [slack: strip], shown: true, enabled: false, settled: true)
        XCTAssertEqual(previews.shownTokens, [])
    }

    func testWithoutScreenRecordingThereIsNoPanel() {
        let previews = controller(allowed: false)
        previews.update(workspaceId: workspace, strips: [slack: strip], shown: true, enabled: true, settled: true)
        XCTAssertEqual(previews.shownTokens, [])
    }

    func testTheLastFrameOfTheLatestWindowsIsKept() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 4, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
        )
        let frame = try XCTUnwrap(OverviewPreviewFrame(pixelBuffer: try XCTUnwrap(buffer)))
        let previews = controller()
        let tokens = (0 ... PartialColumnPreviewController.framesKept).map { WindowToken(pid: 9, windowId: 900 + $0) }
        for token in tokens {
            previews.keep(frame, for: token)
        }
        XCTAssertEqual(previews.keptFrames.count, PartialColumnPreviewController.framesKept)
        XCTAssertFalse(previews.keptFrames.contains(tokens[0]))
        // Kept again, a window is the latest: the next one in drops another.
        previews.keep(frame, for: tokens[1])
        previews.keep(frame, for: WindowToken(pid: 9, windowId: 999))
        XCTAssertTrue(previews.keptFrames.contains(tokens[1]))
        XCTAssertFalse(previews.keptFrames.contains(tokens[2]))
    }

    func testAFramesPixelsPerPointAreItsBackingScaleTimesItsFit() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, 2062, 2588, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer
        )
        let pixels = try XCTUnwrap(buffer)
        // A 2x window fitted, after a split, into a buffer made for its size before: shown at 2 x 0.64.
        let fitted = try XCTUnwrap(OverviewPreviewFrame(
            pixelBuffer: pixels, contentRect: CGRect(x: 0, y: 0, width: 1031, height: 413),
            scaleFactor: 2, contentScale: 0.64
        ))
        XCTAssertEqual(fitted.pixelsPerPoint, 1.28, accuracy: 0.0001)
        // A window last drawn on a 1x display: a pixel a point, whatever the panel's display.
        let oneX = try XCTUnwrap(OverviewPreviewFrame(
            pixelBuffer: pixels, contentRect: CGRect(x: 0, y: 0, width: 1031, height: 1294), scaleFactor: 1
        ))
        XCTAssertEqual(oneX.pixelsPerPoint, 1)
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
