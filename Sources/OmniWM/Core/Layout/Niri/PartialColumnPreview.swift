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
    private var tokensByWorkspace: [WorkspaceDescriptor.ID: Set<WindowToken>] = [:]

    init(system: System) {
        self.system = system
    }

    /// What workspace `workspaceId`'s layout found: the strips of its hidden partial columns, whether it
    /// is shown with the setting on (`active`), and whether it has stopped moving (`settled`). Panels and
    /// their streams stay through relayout and motion; one goes when its column is back in view once
    /// settled, when the workspace is not shown, or when the setting is off.
    func update(
        workspaceId: WorkspaceDescriptor.ID,
        strips: [WindowToken: NiriPartialStrip],
        active: Bool,
        settled: Bool
    ) {
        let allowed = active && system.captureAllowed()
        var kept = Set<WindowToken>()
        for token in tokensByWorkspace[workspaceId] ?? [] {
            if !allowed {
                remove(token, why: active ? "no Screen Recording" : "workspace not shown or setting off")
            } else if settled, strips[token] == nil {
                remove(token, why: "column back in view")
            } else {
                kept.insert(token)
            }
        }
        if allowed {
            for (token, strip) in strips {
                let panel = panels[token] ?? makePanel(for: token)
                panels[token] = panel
                panel.show(strip)
                kept.insert(token)
            }
        }
        tokensByWorkspace[workspaceId] = kept.isEmpty ? nil : kept
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
    }

    var shownTokens: Set<WindowToken> {
        Set(panels.keys)
    }

    private func makePanel(for token: WindowToken) -> PartialColumnPreviewPanel {
        Log.preview.notice("partial column preview created for window \(token.windowId)")
        let panel = PartialColumnPreviewPanel(windowId: token.windowId, onClick: { [system] in system.focus(token) })
        guard let handle = system.handle(token) else { return panel }
        panel.startStream = { [system, weak panel] size, generation in
            guard let window = await system.window(token), let panel else { return }
            let scale = system.scale(panel.frame)
            let request = OverviewPreviewRequest(
                handle: handle,
                pixelWidth: Int((size.width * scale).rounded()),
                pixelHeight: Int((size.height * scale).rounded())
            )
            await panel.attach(window: window, request: request, generation: generation)
        }
        return panel
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
    /// Bumped as a stream is stopped: a start begun before it attaches nothing. (A task's own
    /// `isCancelled` needs a runtime symbol macOS 26 lacks.)
    private var generation = 0
    private var destroyed = false
    var startStream: (@MainActor (CGSize, Int) async -> Void)?

    init(windowId: Int, onClick: @escaping @MainActor () -> Void) {
        self.windowId = windowId
        self.onClick = onClick
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = false
        isOpaque = false
        backgroundColor = .clear
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
        contentLayer.contentsGravity = .resize
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

    private func takeFrame() {
        guard let frame = output?.take() else { return }
        let previous = frameShown
        if previous == nil {
            Log.preview.notice("partial column preview first frame for window \(self.windowId)")
        }
        frameShown = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { withExtendedLifetime(previous) {} }
        contentLayer.contents = frame.surface
        CATransaction.commit()
        applyCrop()
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
            active: isActiveWorkspace && pass.engine.partialColumnPreview,
            settled: isSettled
        )
    }
}
