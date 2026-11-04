// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ScreenCaptureKit

/// A live view of a column hidden because it would run onto a neighbouring display
/// (`niri.partialColumnPreview`): a borderless panel over the strip it would take on its own display,
/// showing a ScreenCaptureKit stream of its window cropped to that strip. A click focuses the window.
/// A panel and its stream stay through relayout and motion, and go once the column is back in view, the
/// workspace is not shown or the setting is off; without Screen Recording there is no panel.
@MainActor
final class PartialColumnPreviewController {
    struct System {
        let captureAllowed: @MainActor () -> Bool
        let handle: @MainActor (WindowToken) -> WindowHandle?
        let window: @MainActor (WindowToken) async -> SCWindow?
        let scale: @MainActor (CGRect) -> CGFloat
        let focus: @MainActor (WindowToken) -> Void
    }

    private let system: System
    private var panels: [WindowToken: PartialColumnPreviewPanel] = [:]
    /// Each window's last frame, which a panel made again shows at once, the stream replacing it; the
    /// last `framesKept` windows' alone.
    private var lastFrames: [WindowToken: OverviewPreviewFrame] = [:]
    private var framesOrder: [WindowToken] = []
    nonisolated static let framesKept = 16
    private var tokensByWorkspace: [WorkspaceDescriptor.ID: Set<WindowToken>] = [:]
    private var skips: [WorkspaceDescriptor.ID: String] = [:]

    init(system: System) {
        self.system = system
    }

    /// What workspace `workspaceId`'s layout found: the strips of its hidden partial columns, whether
    /// it is shown, whether the setting is on, and whether it has stopped moving. Panels and their
    /// streams stay through relayout and motion; one goes when its column is back in view once
    /// settled, when the workspace is not shown, or when the setting is off. A strip left empty says
    /// why, once each time the reason changes.
    func update(
        workspaceId: WorkspaceDescriptor.ID,
        strips: [WindowToken: NiriPartialStrip],
        shown: Bool,
        enabled: Bool,
        settled: Bool
    ) {
        let skipped: String? = if !enabled {
            "setting off"
        } else if !shown {
            "workspace not shown"
        } else if !system.captureAllowed() {
            "no Screen Recording"
        } else {
            nil
        }
        noteSkip(workspaceId, strips: strips, why: skipped)
        var kept = Set<WindowToken>()
        for token in tokensByWorkspace[workspaceId] ?? [] {
            if let skipped {
                remove(token, why: skipped)
            } else if settled, strips[token] == nil {
                remove(token, why: "column back in view")
            } else {
                kept.insert(token)
            }
        }
        if skipped == nil {
            for (token, strip) in strips {
                // A panel is made only once the layout settles: never mid-animation or mid-resize.
                guard let panel = panels[token] ?? (settled ? makePanel(for: token) : nil) else { continue }
                panels[token] = panel
                panel.show(strip)
                kept.insert(token)
            }
        }
        tokensByWorkspace[workspaceId] = kept.isEmpty ? nil : kept
    }

    /// Says once, each time it changes, why a workspace's hidden partial columns show no live view.
    private func noteSkip(
        _ workspaceId: WorkspaceDescriptor.ID,
        strips: [WindowToken: NiriPartialStrip],
        why: String?
    ) {
        let reason = strips.isEmpty ? nil : why
        guard skips[workspaceId] != reason else { return }
        skips[workspaceId] = reason
        guard let reason else { return }
        let windows = strips.keys.map { String($0.windowId) }.sorted().joined(separator: ", ")
        Log.preview.notice("partial column preview skipped for window(s) \(windows): \(reason)")
    }

    private func remove(_ token: WindowToken, why: String) {
        guard let panel = panels.removeValue(forKey: token) else { return }
        Log.preview.notice("partial column preview removed for window \(token.windowId): \(why)")
        panel.destroy()
    }

    func removeAll() {
        for panel in panels.values {
            panel.destroy()
        }
        panels.removeAll()
        tokensByWorkspace.removeAll()
        skips.removeAll()
    }

    var shownTokens: Set<WindowToken> {
        Set(panels.keys)
    }

    private func makePanel(for token: WindowToken) -> PartialColumnPreviewPanel {
        Log.preview.notice("partial column preview created for window \(token.windowId)")
        let panel = PartialColumnPreviewPanel(windowId: token.windowId, onClick: { [system] in system.focus(token) })
        panel.onFrame = { [weak self] frame in self?.keep(frame, for: token) }
        if let last = lastFrames[token] { panel.preload(last) }
        guard let handle = system.handle(token) else { return panel }
        panel.startStream = { [system, weak panel] size, generation in
            guard let window = await system.window(token), let panel else { return }
            let scale = system.scale(panel.frame)
            // The window's size as the layout made it, so its pixels come 1:1, not scaled to fit. Never
            // the SCWindow's frame: that is the one discovery saw, stale once a split or resize has
            // changed the window's size.
            let request = OverviewPreviewRequest(
                handle: handle,
                pixelWidth: Int((size.width * scale).rounded()),
                pixelHeight: Int((size.height * scale).rounded())
            )
            await panel.attach(window: window, request: request, generation: generation)
        }
        return panel
    }

    func keep(_ frame: OverviewPreviewFrame, for token: WindowToken) {
        lastFrames[token] = frame
        framesOrder.removeAll { $0 == token }
        framesOrder.append(token)
        while framesOrder.count > Self.framesKept {
            lastFrames.removeValue(forKey: framesOrder.removeFirst())
        }
    }

    var keptFrames: Set<WindowToken> {
        Set(lastFrames.keys)
    }
}

/// One strip's panel: over the desktop, under every window, never key.
@MainActor
final class PartialColumnPreviewPanel: NSPanel {
    private let contentLayer = CALayer()
    private let windowId: Int
    private let onClick: @MainActor () -> Void
    private var strip: NiriPartialStrip?
    private var output: OverviewPreviewStream?
    private var control: (any OverviewPreviewStreamControl)?
    private var frameShown: OverviewPreviewFrame?
    private var streamedSize: CGSize?
    private var startTask: Task<Void, Never>?
    private var streamed = false
    /// Bumped as a stream is stopped: a start begun before it attaches nothing. (A task's own
    /// `isCancelled` needs a runtime symbol macOS 26 lacks.)
    private var generation = 0
    private var destroyed = false
    var startStream: (@MainActor (CGSize, Int) async -> Void)?
    /// Told each frame shown, so the window's last one outlives the panel.
    var onFrame: (@MainActor (OverviewPreviewFrame) -> Void)?

    init(windowId: Int, onClick: @escaping @MainActor () -> Void) {
        self.windowId = windowId
        self.onClick = onClick
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = false
        isOpaque = false
        backgroundColor = .clear
        // Nothing drawn until there is a picture: never an empty or black strip.
        alphaValue = 0
        // Above the desktop, under every window: the strip is the desktop.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer = contentLayer
        // The window's pixels at their own size, from the strip's top left: never stretched to the panel.
        contentLayer.contentsGravity = .topLeft
        contentView = view
        if windowNumber > 0 {
            SkyLight.shared.excludeFromScreencaptureWindowSelection(UInt32(windowNumber))
        }
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    override func mouseDown(with _: NSEvent) {
        onClick()
    }

    func show(_ next: NiriPartialStrip) {
        guard !destroyed else { return }
        strip = next
        setFrame(next.strip, display: false)
        contentLayer.frame = CGRect(origin: .zero, size: next.strip.size)
        applyCrop()
        orderFrontRegardless()
        // A new stream when the window's size changes; the same one while only the strip moves.
        guard streamedSize != next.frame.size, let startStream else { return }
        streamedSize = next.frame.size
        stopStream()
        let started = generation
        startTask = Task { await startStream(next.frame.size, started) }
    }

    func attach(window: SCWindow, request: OverviewPreviewRequest, generation started: Int) async {
        guard !destroyed, started == generation else { return }
        // Only this window's own pixels, never another window's or the display's.
        guard Int(window.windowID) == windowId else {
            Log.preview
                .notice(
                    "partial column preview found window \(window.windowID) for window \(self.windowId): not streamed"
                )
            return
        }
        let output = OverviewPreviewStream(
            onReady: { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.takeFrame() } } },
            onFailure: { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamFailed() } } }
        )
        do {
            let control = try OverviewNativePreviewStream(window: window, request: request, output: output)
            self.output = output
            self.control = control
            try await control.start()
        } catch {
            Log.preview
                .notice(
                    "partial column preview stream failed for window \(self.windowId): \(error.localizedDescription)"
                )
            ScreenCapturePermissionMonitor.shared.noteCaptureFailure(error)
            stopStream()
        }
    }

    /// A frame kept from before, shown at once until the stream's first.
    func preload(_ frame: OverviewPreviewFrame) {
        display(frame)
    }

    private func takeFrame() {
        guard let frame = output?.take() else { return }
        if !streamed {
            streamed = true
            Log.preview.notice("partial column preview first frame for window \(self.windowId)")
        }
        onFrame?(frame)
        display(frame)
    }

    private func display(_ frame: OverviewPreviewFrame) {
        let previous = frameShown
        frameShown = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        contentLayer.contents = frame.surface
        // A point of the window is a point of the panel, whatever scale it was drawn at (a window last
        // drawn on a 1x display, or fitted to a buffer of another size) and whatever the panel's display.
        contentLayer.contentsScale = frame.pixelsPerPoint
        CATransaction.commit()
        applyCrop()
        alphaValue = 1
    }

    /// The strip's part of the window's frame, within the part of the buffer the window takes.
    private func applyCrop() {
        guard let strip else { return }
        let window = frameShown?.contentsRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let unit = strip.unitRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contentsRect = CGRect(
            x: window.minX + unit.minX * window.width,
            y: window.minY + unit.minY * window.height,
            width: unit.width * window.width,
            height: unit.height * window.height
        )
        CATransaction.commit()
    }

    /// The stream stopped by itself: the next `show` starts another.
    private func streamFailed() {
        Log.preview.notice("partial column preview stream stopped for window \(self.windowId)")
        stopStream()
        streamedSize = nil
    }

    private func stopStream() {
        generation += 1
        startTask?.cancel()
        startTask = nil
        output?.invalidate()
        output = nil
        control?.stop()
        control = nil
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        stopStream()
        contentLayer.contents = nil
        frameShown = nil
        orderOut(nil)
        close()
    }
}

extension NiriLayoutHandler {
    func makePartialColumnPreviews() -> PartialColumnPreviewController {
        PartialColumnPreviewController(system: .init(
            captureAllowed: { ScreenCapturePermissionMonitor.shared.isGranted },
            handle: { [weak self] in self?.controller?.workspaceManager.handle(for: $0) },
            window: { await PreviewCaptureCoordinator.shared.window(for: $0).window },
            scale: { rect in NSScreen.screens.first { $0.frame.intersects(rect) }?.backingScaleFactor ?? 2 },
            focus: { [weak self] in _ = self?.controller?.focusWindow($0) }
        ))
    }

    /// A hidden partial column's live view: on the active workspace once settled, none while it moves.
    func updatePartialColumnPreviews(pass: NiriLayoutPass, isActiveWorkspace: Bool, isSettled: Bool) {
        partialColumnPreviews.update(
            workspaceId: pass.wsId,
            strips: pass.engine.partialStrips[pass.wsId] ?? [:],
            shown: isActiveWorkspace,
            enabled: pass.engine.partialColumnPreview,
            settled: isSettled
        )
    }
}
