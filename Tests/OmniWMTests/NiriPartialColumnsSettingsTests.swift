// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class NiriPartialColumnsSettingsTests: XCTestCase {
    func testPartialColumnsAcrossDisplaysIsOffByDefaultOptionalAndRoundTrips() throws {
        XCTAssertEqual(SettingsExport.defaults().niri.partialColumnsAcrossDisplays, false)
        var export = SettingsExport.defaults()
        export.niri.partialColumnsAcrossDisplays = true
        let toml = String(decoding: try SettingsTOMLCodec.encode(export), as: UTF8.self)
        XCTAssertTrue(toml.contains("partialColumnsAcrossDisplays = true"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(Data(toml.utf8)).niri.partialColumnsAcrossDisplays, true)
        let without = toml.components(separatedBy: "\n").filter { !$0.hasPrefix("partialColumnsAcrossDisplays") }
        XCTAssertNil(try SettingsTOMLCodec.decode(Data(without.joined(separator: "\n").utf8)).niri
            .partialColumnsAcrossDisplays)
    }
}
