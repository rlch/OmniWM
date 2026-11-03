// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

extension AXWindowService {
    private struct FrameWriteOptions {
        let currentFrameHint: CGRect?
        let components: AXFrameComponents
        let verify: Bool
    }

    private enum FrameWriteAttribute {
        case size
        case position
    }

    static func frameWriteOrder(currentFrame: CGRect?, targetFrame: CGRect) -> AXFrameWriteOrder {
        guard let currentFrame else {
            return .sizeThenPosition
        }
        if targetFrame.width > currentFrame.width + 0.5 || targetFrame.height > currentFrame.height + 0.5 {
            return .positionThenSize
        }
        return .sizeThenPosition
    }

    /// Where to put a window before it grows past its screen's trailing edge, or nil when it need not
    /// move first: AX grows a window whose trailing edge is on screen only as far as that edge, and one
    /// whose edge is already past it as far as asked. The window keeps its size and row, and 40 points
    /// on screen, which AX keeps of any window it moves.
    static func overflowStaging(currentFrame: CGRect?, targetFrame: CGRect, screens: [CGRect]) -> CGRect? {
        guard let currentFrame,
              targetFrame.width > currentFrame.width + 0.5,
              let screen = screens.first(where: { $0.contains(CGPoint(x: targetFrame.minX, y: targetFrame.midY)) })
              ?? screens.first(where: { $0.intersects(targetFrame) }),
              targetFrame.maxX > screen.maxX + 0.5,
              currentFrame.maxX <= screen.maxX + 0.5
        else { return nil }
        return CGRect(origin: CGPoint(x: screen.maxX - 40, y: currentFrame.minY), size: currentFrame.size)
    }

    private static func stagingPosition(currentFrame: CGRect?, targetFrame: CGRect) -> AXValue? {
        let screens = NSScreen.screens.map(\.frame)
        guard let rect = overflowStaging(currentFrame: currentFrame, targetFrame: targetFrame, screens: screens)
        else { return nil }
        var origin = convertToAX(rect).origin
        return AXValueCreate(.cgPoint, &origin)
    }

    static func setFrame(
        _ window: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect? = nil,
        components: AXFrameComponents = .all,
        verify: Bool = true
    ) -> AXFrameWriteResult {
        setFrame(
            window,
            frame: frame,
            options: FrameWriteOptions(currentFrameHint: currentFrameHint, components: components, verify: verify),
            timing: nil
        )
    }

    private static func setFrame(
        _ window: AXWindowRef,
        frame: CGRect,
        options: FrameWriteOptions,
        timing: UnsafeMutablePointer<AXFrameSetterTiming>?
    ) -> AXFrameWriteResult {
        let currentFrameHint = options.currentFrameHint
        let components = options.components
        let verify = options.verify
        precondition(!components.isEmpty)
        var currentFrame = currentFrameHint
        if components == .all, currentFrame == nil {
            let start = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            currentFrame = try? self.frame(window)
            if let timing { timing.pointee.preReadNs = elapsedNanoseconds(since: start) }
        }
        let writeOrder = components == .all
            ? frameWriteOrder(currentFrame: currentFrame, targetFrame: frame)
            : .sizeThenPosition
        let staging = components == .all ? stagingPosition(currentFrame: currentFrame, targetFrame: frame) : nil
        let axFrame = convertToAX(frame)
        var position = CGPoint(x: axFrame.origin.x, y: axFrame.origin.y)
        var size = CGSize(width: axFrame.size.width, height: axFrame.size.height)
        let positionValue = components.contains(.position) ? AXValueCreate(.cgPoint, &position) : nil
        let sizeValue = components.contains(.size) ? AXValueCreate(.cgSize, &size) : nil
        guard !components.contains(.position) || positionValue != nil,
              !components.contains(.size) || sizeValue != nil
        else {
            return .skipped(
                targetFrame: frame,
                currentFrameHint: currentFrameHint,
                failureReason: .valueCreationFailed,
                components: components
            )
        }

        let (sizeError, positionError) = setFrameAttributes(
            window, values: (sizeValue, positionValue), order: writeOrder, staging: staging, timing: timing
        )

        let verificationStart = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        let observedFrame = verify ? (try? self.frame(window)) : nil
        if let timing {
            timing.pointee.verificationNs = elapsedNanoseconds(since: verificationStart)
        }

        let failureReason = frameWriteFailure(
            errors: (sizeError, positionError), observedFrame: observedFrame, frame: frame, options: options
        )

        return AXFrameWriteResult(
            observedFrame: observedFrame,
            writeOrder: writeOrder,
            sizeError: sizeError,
            positionError: positionError,
            failureReason: failureReason,
            components: components
        )
    }

    static func setFrameTraced(
        _ window: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect? = nil,
        components: AXFrameComponents = .all,
        verify: Bool = true
    ) -> (result: AXFrameWriteResult, timing: AXFrameSetterTiming) {
        var timing = AXFrameSetterTiming()
        let result = withUnsafeMutablePointer(to: &timing) { pointer in
            setFrame(
                window,
                frame: frame,
                options: FrameWriteOptions(currentFrameHint: currentFrameHint, components: components, verify: verify),
                timing: pointer
            )
        }
        return (result, timing)
    }

    private static func frameWriteFailure(
        errors: (size: AXError, position: AXError),
        observedFrame: CGRect?,
        frame: CGRect,
        options: FrameWriteOptions
    ) -> AXFrameWriteFailureReason? {
        if errors.size != .success {
            mapFrameWriteFailure(errors.size, attribute: .size)
        } else if errors.position != .success {
            mapFrameWriteFailure(errors.position, attribute: .position)
        } else if !options.verify {
            nil
        } else if let observedFrame {
            axFrameMatches(observedFrame, target: frame, components: options.components) ? nil : .verificationMismatch
        } else {
            .readbackFailed
        }
    }

    private static func setFrameAttributes(
        _ window: AXWindowRef,
        values: (size: AXValue?, position: AXValue?),
        order: AXFrameWriteOrder,
        staging: AXValue?,
        timing: UnsafeMutablePointer<AXFrameSetterTiming>?
    ) -> (AXError, AXError) {
        var positionError: AXError = .success
        var sizeError: AXError = .success

        func setSize() -> AXError {
            guard let sizeValue = values.size else { return .success }
            let start = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, sizeValue)
            if let timing {
                timing.pointee.sizeNs = elapsedNanoseconds(since: start)
            }
            return error
        }

        func setPosition() -> AXError {
            guard let positionValue = values.position else { return .success }
            let start = timing == nil ? 0 : DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementSetAttributeValue(
                window.element,
                kAXPositionAttribute as CFString,
                positionValue
            )
            if let timing {
                timing.pointee.positionNs = elapsedNanoseconds(since: start)
            }
            return error
        }

        // Past the screen's trailing edge first, so the size is not clamped to it; then the size, then the place.
        if let staging {
            _ = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, staging)
        }
        switch staging == nil ? order : .sizeThenPosition {
        case .sizeThenPosition:
            sizeError = setSize()
            positionError = setPosition()
        case .positionThenSize:
            positionError = setPosition()
            sizeError = setSize()
        }

        return (sizeError, positionError)
    }

    private static func elapsedNanoseconds(since start: UInt64) -> UInt64 {
        let end = DispatchTime.now().uptimeNanoseconds
        return end >= start ? end - start : 0
    }

    private static func convertToAX(_ rect: CGRect) -> CGRect {
        ScreenCoordinateSpace.toWindowServer(rect: rect)
    }

    private static func mapFrameWriteFailure(
        _ error: AXError,
        attribute: FrameWriteAttribute
    ) -> AXFrameWriteFailureReason {
        if error == .invalidUIElement || error == .cannotComplete {
            return .staleElement
        }

        return switch attribute {
        case .size:
            .sizeWriteFailed(error)
        case .position:
            .positionWriteFailed(error)
        }
    }
}
