import AppKit
import SwiftUI

/// The Settings window, created on first use and kept for later.
@MainActor
final class SettingsWindowController {
    private let makeViewModel: () -> SettingsViewModel
    private var window: NSWindow?
    private var viewModel: SettingsViewModel?

    init(makeViewModel: @escaping () -> SettingsViewModel) {
        self.makeViewModel = makeViewModel
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
            window.contentView = NSHostingView(rootView: SettingsView(viewModel: viewModel))
            window.center()
            self.viewModel = viewModel
            self.window = window
        }
        viewModel?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
