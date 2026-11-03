// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ScreenCaptureKit

/// A live view of a column hidden because it would run onto a neighbouring display
/// (`niri.partialColumnPreview`): a borderless panel over the strip it would take on its own display,
/// showing a ScreenCaptureKit stream of its window cropped to that strip. A click focuses the window.
/// It streams only while the strip is shown, the workspace is active and the layout settled; without
/// Screen Recording there is no panel and the strip stays empty, as before.
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

    /// The strips workspace `workspaceId` shows now; none to take its panels away.
    func update(workspaceId: WorkspaceDescriptor.ID, strips: [WindowToken: NiriPartialStrip]) {
        let wanted = system.captureAllowed() ? strips : [:]
        for token in tokensByWorkspace[workspaceId] ?? [] where wanted[token] == nil {
            panels.removeValue(forKey: token)?.destroy()
        }
        for (token, strip) in wanted {
            let panel = panels[token] ?? makePanel(for: token)
            panels[token] = panel
            panel.show(strip)
        }
        tokensByWorkspace[workspaceId] = wanted.isEmpty ? nil : Set(wanted.keys)
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
        let panel = PartialColumnPreviewPanel(onClick: { [system] in system.focus(token) })
        guard let handle = system.handle(token) else { return panel }
        panel.startStream = { [system, weak panel] size in
            guard let window = await system.window(token), let panel else { return }
            let scale = system.scale(panel.frame)
            let request = OverviewPreviewRequest(
                handle: handle,
                pixelWidth: Int((size.width * scale).rounded()),
                pixelHeight: Int((size.height * scale).rounded())
            )
            await panel.attach(window: window, request: request)
        }
        return panel
    }
}

/// One strip's panel: over the desktop, under every window, never key.
@MainActor
final class PartialColumnPreviewPanel: NSPanel {
    private let contentLayer = CALayer()
    private let onClick: @MainActor () -> Void
    private var strip: NiriPartialStrip?
    private var output: OverviewPreviewStream?
    private var control: (any OverviewPreviewStreamControl)?
    private var frameShown: OverviewPreviewFrame?
    private var streamedSize: CGSize?
    private var startTask: Task<Void, Never>?
    private var destroyed = false
    var startStream: (@MainActor (CGSize) async -> Void)?

    init(onClick: @escaping @MainActor () -> Void) {
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
        orderFront(nil)
        // A new stream when the window's size changes; the same one while only the strip moves.
        guard streamedSize != next.frame.size, let startStream else { return }
        streamedSize = next.frame.size
        stopStream()
        startTask = Task { await startStream(next.frame.size) }
    }

    func attach(window: SCWindow, request: OverviewPreviewRequest) async {
        guard !destroyed, startTask?.isCancelled != true else { return }
        let output = OverviewPreviewStream(
            onReady: { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.takeFrame() } } },
            onFailure: { [weak self] in DispatchQueue.main.async { MainActor.assumeIsolated { self?.stopStream() } } }
        )
        do {
            let control = try OverviewNativePreviewStream(window: window, request: request, output: output)
            self.output = output
            self.control = control
            try await control.start()
        } catch {
            ScreenCapturePermissionMonitor.shared.noteCaptureFailure(error)
            stopStream()
        }
    }

    private func takeFrame() {
        guard let frame = output?.take() else { return }
        let previous = frameShown
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

    private func stopStream() {
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
            strips: isActiveWorkspace && isSettled ? pass.engine.partialStrips[pass.wsId] ?? [:] : [:]
        )
    }
}
