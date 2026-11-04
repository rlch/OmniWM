// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@preconcurrency import AppKit
import Carbon
import Foundation
import IOKit.hidsystem

extension HotkeyCenter {
    nonisolated static func bindingFacts(for bindings: [HotkeyBinding]) -> [HotkeyBindingFact] {
        let failures = registrationPlan(for: bindings).failures
        return bindings.compactMap { binding in
            let trigger = binding.binding
            guard !trigger.isUnassigned else { return nil }
            let route = failures[binding.command].map { "unregistered(\($0))" } ?? registeredRoute(for: binding)
            return HotkeyBindingFact(command: binding.command.displayName, display: trigger.displayString, route: route)
        }
    }

    private nonisolated static func registeredRoute(for binding: HotkeyBinding) -> String {
        let trigger = binding.binding
        if trigger.mouseButtonBinding != nil { return "mouse" }
        if routesThroughTap(binding) {
            return binding.passthroughBundleIDs.isEmpty ? "sided" : "passthrough"
        }
        return "carbon"
    }

    /// A sided chord, or one that lets its key through to chosen apps, is matched on the event tap:
    /// Carbon's RegisterEventHotKey can neither tell sides apart nor hand a key back to the app.
    nonisolated static func routesThroughTap(_ binding: HotkeyBinding) -> Bool {
        guard let chord = binding.binding.chordBinding else { return false }
        return !chord.sidedModifiers.isEmpty || !binding.passthroughBundleIDs.isEmpty
    }

    static func decisionLabel(_ decision: HyperTriggerStateMachine.Decision) -> String {
        switch decision {
        case .suppress: "suppress"
        case .passThrough: "passThrough"
        case .inject: "inject"
        case .toggleCapsLock: "toggleCapsLock"
        }
    }

    nonisolated static func inputMonitoringAccessGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    nonisolated static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    nonisolated static func registrationPlan(for bindings: [HotkeyBinding]) -> HotkeyRegistrationPlan {
        let candidates = bindings.filter { !$0.binding.isUnassigned }

        var failures: [HotkeyCommand: HotkeyRegistrationFailureReason] = [:]
        for index in candidates.indices {
            let overlaps = candidates.indices.contains { other in
                other != index && candidates[index].binding.conflicts(with: candidates[other].binding)
            }
            if overlaps {
                failures[candidates[index].command] = .duplicateBinding
            }
        }

        var registrations: [HotkeyPlannedRegistration] = []
        var sideSpecific: [HotkeyPlannedRegistration] = []
        var mouseButtons: [MouseButtonBinding: HotkeyCommand] = [:]
        for candidate in candidates where failures[candidate.command] == nil {
            switch candidate.binding {
            case let .chord(binding):
                let registration = HotkeyPlannedRegistration(
                    binding: binding,
                    command: candidate.command,
                    passthroughBundleIDs: Set(candidate.passthroughBundleIDs)
                )
                if routesThroughTap(candidate) {
                    sideSpecific.append(registration)
                } else {
                    registrations.append(registration)
                }
            case let .mouseButton(binding):
                mouseButtons[binding] = candidate.command
            case .unassigned:
                break
            }
        }

        return HotkeyRegistrationPlan(
            registrations: registrations,
            sideSpecificRegistrations: sideSpecific,
            mouseButtonRegistrations: mouseButtons,
            failures: failures
        )
    }
}
