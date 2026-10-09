import AppKit
import ApplicationServices
import CoreGraphics
import os

private let log = Logger(subsystem: "dev.idesk.app", category: "Permissions")

/// The two privacy permissions iDesk uses, and the System Settings panes
/// where the user grants them.
enum PermissionService {
    /// Whether iDesk is on in Privacy & Security → Accessibility, which lets
    /// it press the Mission Control shortcuts. `AXIsProcessTrusted` follows
    /// the switch live; the CoreGraphics check can keep its first answer
    /// until the app restarts.
    static var canSwitchDesktops: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    /// Asks macOS for Accessibility access; it adds iDesk to the list.
    @discardableResult
    static func requestSwitchDesktops() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) || CGRequestPostEventAccess()
    }

    /// Whether iDesk may take the small desktop previews.
    static var canCapturePreviews: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestCapturePreviews() -> Bool { CGRequestScreenCaptureAccess() }

    static func logState() {
        log.notice("Accessibility trusted: \(AXIsProcessTrusted(), privacy: .public), post events: \(CGPreflightPostEventAccess(), privacy: .public)")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openKeyboardShortcutSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }
}
