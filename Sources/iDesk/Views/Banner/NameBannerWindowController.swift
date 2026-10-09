import AppKit
import Combine
import SwiftUI

/// A click-through panel over the screen that shows the name banner while
/// its view model says it is presented.
@MainActor
final class NameBannerWindowController {
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: NameBannerViewModel) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: NameBannerView(viewModel: viewModel))
        host.sizingOptions = []
        panel.contentView = host

        viewModel.$screen
            .compactMap { $0 }
            .sink { [weak self] screen in
                guard let self, self.panel.frame != screen.visibleFrame else { return }
                self.panel.setFrame(screen.visibleFrame, display: false)
            }
            .store(in: &cancellables)
        viewModel.$isPresented
            .removeDuplicates()
            .sink { [weak self] presented in
                if presented { self?.panel.orderFrontRegardless() } else { self?.panel.orderOut(nil) }
            }
            .store(in: &cancellables)
    }
}
