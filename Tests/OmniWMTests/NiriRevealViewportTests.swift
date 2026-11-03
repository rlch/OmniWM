// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

@MainActor
final class NiriRevealViewportTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let windows: [NiriWindow]
        let workingFrame: CGRect
        let gap: CGFloat
        var state: ViewportState

        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }

        var context: NiriInteractionContext {
            .init(
                workspaceId: workspaceId,
                motion: .disabled,
                workingFrame: workingFrame,
                gaps: gap,
                orientation: .horizontal
            )
        }

        /// Where the view starts, from the leading edge of column `index`.
        func viewStart(from index: Int) -> CGFloat {
            state.columnX(at: state.activeColumnIndex, columns: columns, gap: gap) + state.viewOffset
                - state.columnX(at: index, columns: columns, gap: gap)
        }
    }

    /// Three columns, 400, 4,000 and 400 points wide, in a 1,000 point view, the wide one focused at its left edge.
    private func makeFixture(wide: CGFloat = 4000) -> Fixture {
        let engine = NiriLayoutEngine(visibleContainerCount: 3)
        engine.defaultContainerPrimarySpan = nil
        let workspaceId = WorkspaceDescriptor.ID()
        let windows = (1 ... 3).map {
            engine.addWindow(token: WindowToken(pid: 615, windowId: $0), to: workspaceId, afterSelection: nil)
        }
        let workingFrame = CGRect(x: 0, y: 0, width: 1000, height: 900)
        for (column, width) in zip(engine.columns(in: workspaceId), [CGFloat(400), wide, 400]) {
            column.width = .fixed(width)
            column.cachedWidth = width
        }
        var state = ViewportState(selectedNodeId: windows[1].id)
        state.activeColumnIndex = 1
        state.jumpOffset(to: 0)
        return Fixture(
            engine: engine, workspaceId: workspaceId, windows: windows,
            workingFrame: workingFrame, gap: 10, state: state
        )
    }

    private func visibleOffset(_ fixture: Fixture, from viewStart: CGFloat, center: CenterFocusedColumn) -> CGFloat {
        let columns = fixture.columns
        let columnStart = fixture.state.columnX(at: 1, columns: columns, gap: fixture.gap)
        return fixture.state.computeVisibleOffset(
            containerIndex: 1,
            containers: columns,
            context: fixture.context,
            currentViewStart: columnStart + viewStart,
            centerMode: center,
            scale: 2
        )
    }

    func testRevealNarrowsThePanToItsSpanByTheCenteringSetting() {
        var fixture = makeFixture()
        fixture.state.reveal = ViewportReveal(token: fixture.windows[1].token, offset: 2000, span: 800)
        // Least pan: the span's end, with a gap after it, at the view's end.
        XCTAssertEqual(visibleOffset(fixture, from: 0, center: .never), 2800 + 10 - 1000, accuracy: 0.001)
        XCTAssertEqual(visibleOffset(fixture, from: 0, center: .onOverflow), 1810, accuracy: 0.001)
        // Centered: the span in the view's middle.
        XCTAssertEqual(visibleOffset(fixture, from: 0, center: .always), 2000 - 100, accuracy: 0.001)
        // From past the span, the least pan puts its start, after a gap, at the view's start.
        XCTAssertEqual(visibleOffset(fixture, from: 3000, center: .never), 2000 - 10, accuracy: 0.001)
    }

    func testRevealAlreadyInViewDoesNotPan() {
        var fixture = makeFixture()
        fixture.state.reveal = ViewportReveal(token: fixture.windows[1].token, offset: 2000, span: 800)
        XCTAssertEqual(visibleOffset(fixture, from: 1950, center: .never), 1950, accuracy: 0.001)
    }

    func testWithoutRevealAWideColumnShowsItsLeadingEdge() {
        let fixture = makeFixture()
        XCTAssertEqual(visibleOffset(fixture, from: 1500, center: .never), 0, accuracy: 0.001)
        XCTAssertEqual(visibleOffset(fixture, from: 1500, center: .always), 0, accuracy: 0.001)
    }

    func testRevealIsClampedInsideItsColumn() {
        var fixture = makeFixture()
        fixture.state.reveal = ViewportReveal(token: fixture.windows[1].token, offset: 3800, span: 800)
        // Only the last 200 points are the window's: they end the view, a gap after them.
        XCTAssertEqual(visibleOffset(fixture, from: 0, center: .never), 4000 + 10 - 1000, accuracy: 0.001)
    }

    func testRevealOfAColumnThatFitsTheViewIsNothing() {
        var fixture = makeFixture(wide: 900)
        let unrevealed = visibleOffset(fixture, from: 0, center: .never)
        fixture.state.reveal = ViewportReveal(token: fixture.windows[1].token, offset: 100, span: 300)
        XCTAssertEqual(visibleOffset(fixture, from: 0, center: .never), unrevealed, accuracy: 0.001)
        let columns = fixture.columns
        fixture.state.ensureContainerVisible(
            containerIndex: 1,
            containers: columns,
            context: fixture.context,
            animate: false
        )
        XCTAssertNil(fixture.state.reveal)
    }

    func testEveryLaterLayoutKeepsTheRevealedSpanInView() {
        var fixture = makeFixture()
        fixture.state.reveal = ViewportReveal(token: fixture.windows[1].token, offset: 2000, span: 800)
        let columns = fixture.columns
        for _ in 0 ..< 3 {
            fixture.state.ensureContainerVisible(
                containerIndex: 1,
                containers: columns,
                context: fixture.context,
                animate: false
            )
            XCTAssertEqual(fixture.viewStart(from: 1), 1810, accuracy: 0.001)
            XCTAssertNotNil(fixture.state.reveal)
        }
    }

    func testFocusOnAnotherColumnClearsTheReveal() {
        var fixture = makeFixture()
        fixture.state.reveal = ViewportReveal(token: fixture.windows[1].token, offset: 2000, span: 800)
        let columns = fixture.columns
        fixture.state.transitionToColumn(
            1,
            columns: columns,
            context: fixture.context,
            animate: false,
            centerMode: .never
        )
        XCTAssertNotNil(fixture.state.reveal)
        fixture.state.transitionToColumn(
            2,
            columns: columns,
            context: fixture.context,
            animate: false,
            centerMode: .never
        )
        XCTAssertNil(fixture.state.reveal)
    }

    func testAPanToAnotherColumnAfterTheRevealShowedClearsIt() {
        var fixture = makeFixture()
        fixture.state.reveal = ViewportReveal(token: fixture.windows[1].token, offset: 2000, span: 800)
        let columns = fixture.columns
        fixture.state.ensureContainerVisible(
            containerIndex: 1, containers: columns, context: fixture.context, animate: false
        )
        XCTAssertEqual(fixture.state.reveal?.shown, true)
        // Focus moved by a path other than a column transition (`window focus`), which pans to its column.
        fixture.state.ensureContainerVisible(
            containerIndex: 2, containers: columns, context: fixture.context, animate: false
        )
        XCTAssertNil(fixture.state.reveal)
    }

    func testARevealOfAWindowGoneIsCleared() {
        var fixture = makeFixture()
        fixture.state.reveal = ViewportReveal(token: WindowToken(pid: 615, windowId: 99), offset: 2000, span: 800)
        let columns = fixture.columns
        fixture.state.ensureContainerVisible(
            containerIndex: 1,
            containers: columns,
            context: fixture.context,
            animate: false
        )
        XCTAssertNil(fixture.state.reveal)
    }

    func testEngineRevealPansTheFocusedColumnOnceAndRefusesAColumnThatFits() {
        var fixture = makeFixture()
        XCTAssertTrue(fixture.engine.reveal(
            fixture.windows[1], offset: 2000, span: 800, context: fixture.context, state: &fixture.state
        ))
        XCTAssertEqual(fixture.viewStart(from: 1), 1810, accuracy: 0.001)
        XCTAssertFalse(fixture.engine.reveal(
            fixture.windows[1], offset: 2000, span: 800, context: fixture.context, state: &fixture.state
        ))
        XCTAssertFalse(fixture.engine.reveal(
            fixture.windows[0], offset: 0, span: 100, context: fixture.context, state: &fixture.state
        ))
        XCTAssertEqual(fixture.state.reveal?.token, fixture.windows[1].token)
    }

    func testEngineRevealOfAnUnfocusedColumnIsKeptWithoutAPan() {
        var fixture = makeFixture()
        let columns = fixture.columns
        fixture.state.transitionToColumn(
            0,
            columns: columns,
            context: fixture.context,
            animate: false,
            centerMode: .never
        )
        let before = fixture.viewStart(from: 0)
        XCTAssertTrue(fixture.engine.reveal(
            fixture.windows[1], offset: 2000, span: 800, context: fixture.context, state: &fixture.state
        ))
        XCTAssertEqual(fixture.viewStart(from: 0), before, accuracy: 0.001)
        fixture.state.transitionToColumn(
            1,
            columns: columns,
            context: fixture.context,
            animate: false,
            centerMode: .never
        )
        XCTAssertEqual(fixture.viewStart(from: 1), 1810, accuracy: 0.001)
    }
}
