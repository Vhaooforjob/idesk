import AppKit
import SwiftUI

/// The Settings window, created on first use and kept for later.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let makeViewModel: () -> SettingsViewModel
    private var window: NSWindow?
    private var viewModel: SettingsViewModel?

    init(makeViewModel: @escaping () -> SettingsViewModel) {
        self.makeViewModel = makeViewModel
        super.init()
    }

    func show() {
        if window == nil {
            let viewModel = makeViewModel()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = String(localized: "iDesk Settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
            window.center()
            self.viewModel = viewModel
            self.window = window
        }
        viewModel?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        updatePreviewVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        viewModel?.preview.setRenderingEnabled(false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updatePreviewVisibility()
    }

    private func updatePreviewVisibility() {
        viewModel?.preview.setRenderingEnabled(window?.occlusionState.contains(.visible) == true)
    }
}
