// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class HotkeyPassthroughTests: XCTestCase {
    private let abyme = "dev.abyme.app"
    private let optionH = KeyBinding(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(optionKey))

    func testDefaultSettingsCarryNoPassthroughList() throws {
        let toml = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)

        XCTAssertFalse(toml.contains("passthroughBundleIDs"))
        XCTAssertTrue(SettingsExport.defaults().hotkeyBindings.allSatisfy(\.passthroughBundleIDs.isEmpty))
    }

    func testPassthroughListParsesAndRoundTripsThroughTOML() throws {
        let canonical = String(decoding: try SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        var lines = canonical.components(separatedBy: "\n")
        let idIndex = try XCTUnwrap(lines.firstIndex(of: #"id = "focus.left""#))
        lines.insert(#"passthroughBundleIDs = ["dev.abyme.app", "com.example.other"]"#, at: idIndex + 1)
        let source = Data(lines.joined(separator: "\n").utf8)

        let result = try SettingsTOMLCodec.decodeForLoad(source)
        let focusLeft = try XCTUnwrap(result.export.hotkeyBindings.first { $0.id == "focus.left" })
        XCTAssertEqual(focusLeft.passthroughBundleIDs, [abyme, "com.example.other"])
        XCTAssertTrue(
            result.export.hotkeyBindings.filter { $0.id != "focus.left" }.allSatisfy(\.passthroughBundleIDs.isEmpty)
        )
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: source), [])

        let reencoded = try SettingsTOMLCodec.encode(result.export)
        XCTAssertTrue(
            String(decoding: reencoded, as: UTF8.self)
                .contains(#"passthroughBundleIDs = ["dev.abyme.app", "com.example.other"]"#)
        )
        XCTAssertEqual(try SettingsTOMLCodec.decode(reencoded).hotkeyBindings, result.export.hotkeyBindings)
    }

    func testPassthroughListSurvivesRebindingAndHyperRetarget() {
        let binding = HotkeyBinding(
            id: "focus.left",
            command: .focus(.left),
            trigger: .chord(optionH),
            passthroughBundleIDs: [abyme]
        )

        let retargeted = HotkeyBindingRegistry.retargetingHyperChords([binding], to: .default)

        XCTAssertEqual(retargeted.first?.passthroughBundleIDs, [abyme])
    }

    func testPassthroughBindingIsPlannedOnTheTapNotCarbon() {
        let bindings = [
            HotkeyBinding(id: "focus.left", command: .focus(.left), trigger: .chord(optionH), passthroughBundleIDs: [abyme]),
            HotkeyBinding(
                id: "focus.right",
                command: .focus(.right),
                binding: KeyBinding(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(optionKey))
            )
        ]

        let plan = HotkeyCenter.registrationPlan(for: bindings)

        XCTAssertEqual(plan.registrations.map(\.command), [.focus(.right)])
        XCTAssertEqual(plan.sideSpecificRegistrations.map(\.command), [.focus(.left)])
        XCTAssertEqual(plan.sideSpecificRegistrations.first?.passthroughBundleIDs, [abyme])
        XCTAssertTrue(plan.failures.isEmpty)
        XCTAssertEqual(
            HotkeyCenter.bindingFacts(for: bindings).map(\.route),
            ["passthrough", "carbon"]
        )
    }

    func testListedFrontmostAppGetsTheKey() throws {
        let frontmost = FrontmostApp(abyme)
        let center = HotkeyCenter(frontmostBundleID: { frontmost.bundleID })
        var invoked: [HotkeyCommand] = []
        center.onCommand = { invoked.append($0.command) }
        center.sideSpecificDispatch = [
            CommandHotkeyTapMatcher.Entry(binding: optionH, command: .focus(.left), passthroughBundleIDs: [abyme])
        ]
        let event = try optionHKeyDown()

        XCTAssertFalse(center.dispatchSideSpecificHotkey(keyCode: optionH.keyCode, event: event))
        XCTAssertEqual(invoked, [])
        XCTAssertTrue(center.suppressedHotkeyKeyCodes.isEmpty)

        frontmost.bundleID = "com.apple.Terminal"
        XCTAssertTrue(center.dispatchSideSpecificHotkey(keyCode: optionH.keyCode, event: event))
        XCTAssertEqual(invoked, [.focus(.left)])
        XCTAssertEqual(center.suppressedHotkeyKeyCodes, [optionH.keyCode])

        center.suppressedHotkeyKeyCodes = []
        frontmost.bundleID = nil
        XCTAssertTrue(center.dispatchSideSpecificHotkey(keyCode: optionH.keyCode, event: event))
        XCTAssertEqual(invoked, [.focus(.left), .focus(.left)])
    }

    func testBindingWithoutListRunsItsActionInAnyApp() throws {
        let center = HotkeyCenter(frontmostBundleID: { "dev.abyme.app" })
        var invoked: [HotkeyCommand] = []
        center.onCommand = { invoked.append($0.command) }
        center.sideSpecificDispatch = [CommandHotkeyTapMatcher.Entry(binding: optionH, command: .focus(.left))]

        XCTAssertTrue(center.dispatchSideSpecificHotkey(keyCode: optionH.keyCode, event: try optionHKeyDown()))
        XCTAssertEqual(invoked, [.focus(.left)])
    }

    private func optionHKeyDown() throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_H), keyDown: true))
        event.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | UInt64(NX_DEVICELALTKEYMASK))
        return event
    }
}

@MainActor
private final class FrontmostApp {
    var bundleID: String?

    init(_ bundleID: String?) {
        self.bundleID = bundleID
    }
}
