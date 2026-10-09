import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "dev.idesk.app", category: "MissionControl")

// Opens and closes Mission Control, the same as pressing its key.
@_silgen_name("CoreDockSendNotification")
private func CoreDockSendNotification(_ notification: CFString, _ unused: Int32)

/// Adds and deletes desktops, as view models need it.
@MainActor
protocol DesktopManaging: AnyObject {
    /// Deletes the desktop at a position in its display's Spaces.
    func removeDesktop(at position: Int, on display: CGDirectDisplayID?) async throws
    func addDesktop(on display: CGDirectDisplayID?) async throws
    /// Opens Mission Control for the user to do it by hand.
    func openMissionControl()
}

enum MissionControlError: LocalizedError {
    case notOpened
    case displayNotFound
    case desktopNotFound
    case refused

    var errorDescription: String? {
        switch self {
        case .notOpened: String(localized: "Mission Control did not show its desktops to iDesk.")
        case .displayNotFound: String(localized: "Mission Control does not show this display.")
        case .desktopNotFound: String(localized: "Mission Control does not show this desktop.")
        case .refused: String(localized: "Mission Control refused the change.")
        }
    }
}

/// macOS has no API to add or delete a desktop, so iDesk does what you
/// would: it opens Mission Control and uses the buttons in its Spaces bar
/// through Accessibility, then closes it again. The approach and the
/// element identifiers come from Hammerspoon's hs.spaces; finding them by
/// position is needed on newer macOS versions.
@MainActor
final class MissionControlService: DesktopManaging {
    /// Mission Control animates in; its buttons work once it has settled.
    private static let settleTime: Duration = .milliseconds(450)
    /// The desktop buttons appear a moment after Mission Control opens.
    private static let openTimeout: TimeInterval = 2.5

    func removeDesktop(at position: Int, on display: CGDirectDisplayID?) async throws {
        try await withSpacesBar(on: display, identifier: "mc.spaces.list") { list in
            let buttons = Self.children(of: list)
            guard buttons.indices.contains(position) else { throw MissionControlError.desktopNotFound }
            guard AXUIElementPerformAction(buttons[position], "AXRemoveDesktop" as CFString) == .success else {
                throw MissionControlError.refused
            }
        }
    }

    func addDesktop(on display: CGDirectDisplayID?) async throws {
        try await withSpacesBar(on: display, identifier: "mc.spaces.add") { button in
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
                throw MissionControlError.refused
            }
        }
    }

    // MARK: Mission Control

    func openMissionControl() {
        if missionControlGroup() == nil { toggleMissionControl() }
    }

    private func withSpacesBar(on display: CGDirectDisplayID?, identifier: String,
                               _ action: (AXUIElement) throws -> Void) async throws {
        let wasOpen = missionControlGroup() != nil
        if !wasOpen { toggleMissionControl() }
        // Only close what iDesk opened, and only if it is still open:
        // toggling a closed Mission Control would open it again.
        let closeIfOpened = { [weak self] in
            guard !wasOpen, let self, self.missionControlGroup() != nil else { return }
            self.toggleMissionControl()
        }

        // The Dock rebuilds Mission Control's elements while it animates
        // in, so look them up again until the Spaces bar is there.
        var lastError: Error = MissionControlError.notOpened
        var found = false
        let start = Date()
        while !found && Date().timeIntervalSince(start) < Self.openTimeout {
            if missionControlGroup() != nil {
                do {
                    _ = try spacesElement(identifier, display: display)
                    found = true
                } catch {
                    lastError = error
                }
            }
            if !found { try await Task.sleep(for: .milliseconds(80)) }
        }
        guard found else {
            closeIfOpened()
            throw lastError
        }
        try await Task.sleep(for: Self.settleTime)

        do {
            guard missionControlGroup() != nil else { throw MissionControlError.notOpened }
            try action(try spacesElement(identifier, display: display))
        } catch {
            closeIfOpened()
            throw error
        }
        // Let the change land before Mission Control closes.
        try await Task.sleep(for: .milliseconds(300))
        closeIfOpened()
    }

    private func toggleMissionControl() {
        CoreDockSendNotification("com.apple.expose.awake" as CFString, 0)
    }

    private func missionControlGroup() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        return Self.children(of: AXUIElementCreateApplication(dock.processIdentifier)).first { Self.identifier(of: $0) == "mc" }
    }

    /// The display's Spaces bar → the element. Newer macOS versions do not
    /// list Mission Control's parts as children of its group, but they are
    /// there on screen: iDesk asks what is at the top of the display and
    /// walks up from it to the Spaces bar.
    private func spacesElement(_ identifier: String, display: CGDirectDisplayID?) throws -> AXUIElement {
        let display = display ?? CGMainDisplayID()
        guard let bar = Self.spacesBar(on: display) else { throw MissionControlError.displayNotFound }
        guard let element = Self.children(of: bar).first(where: { Self.identifier(of: $0) == identifier }) else {
            throw MissionControlError.desktopNotFound
        }
        return element
    }

    // MARK: Accessibility

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    private static func identifier(of element: AXUIElement) -> String? {
        attribute(kAXIdentifierAttribute, of: element) as? String
    }

    private static func displayID(of element: AXUIElement) -> CGDirectDisplayID? {
        let value = attribute("AXDisplayID", of: element)
        if let number = value as? NSNumber { return CGDirectDisplayID(number.uint32Value) }
        if let text = value as? String { return CGDirectDisplayID(text) }
        return nil
    }

    /// Finds the Spaces bar at the top of a display. It is hit-tested at a
    /// few points across the top, and the element found must belong to the
    /// right display, checked by its display number when the Dock gives one.
    private static func spacesBar(on display: CGDirectDisplayID) -> AXUIElement? {
        let bounds = CGDisplayBounds(display)
        let system = AXUIElementCreateSystemWide()
        for y in [bounds.minY + 12, bounds.minY + 30, bounds.minY + 55] {
            for fraction in [0.5, 0.35, 0.65, 0.2, 0.8] {
                var hit: AXUIElement?
                let x = bounds.minX + bounds.width * fraction
                guard AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &hit) == .success, let hit else { continue }
                var bar: AXUIElement?
                var element = hit
                for _ in 0..<6 {
                    let identifier = identifier(of: element)
                    if identifier == "mc.spaces" { bar = element }
                    if identifier == "mc.display" {
                        if let number = displayID(of: element), number != display { bar = nil }
                        break
                    }
                    guard let parent = attribute(kAXParentAttribute, of: element), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                    element = unsafeBitCast(parent, to: AXUIElement.self)
                }
                if let bar { return bar }
            }
        }
        log.error("No Spaces bar found at the top of display \(display, privacy: .public) \(NSStringFromRect(bounds), privacy: .public)")
        return nil
    }
}
