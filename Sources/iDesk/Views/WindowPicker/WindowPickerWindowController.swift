import AppKit
import SwiftUI

@MainActor
final class WindowPickerWindowController {
    private let desktops: DesktopsViewModel
    private let viewModel: WindowPickerViewModel
    private var panel: WindowPickerPanel?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var isLoading = false

    init(desktops: DesktopsViewModel) {
        self.desktops = desktops
        viewModel = WindowPickerViewModel(desktops: desktops)
    }

    func toggle() {
        if panel?.isVisible == true { dismiss(); return }
        if panel == nil {
            let panel = WindowPickerPanel(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = String(localized: "Move a Window")
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.onClose = { [weak self] in self?.loadTask?.cancel() }
            panel.contentView = NSHostingView(rootView: WindowPickerView(viewModel: viewModel,
                submit: { [weak self] in self?.submit() }, cancel: { [weak self] in self?.dismiss() },
                refresh: { [weak self] in self?.reload() }, openAccessibility: { [weak self] in
                    self?.dismiss()
                    PermissionService.requestSwitchDesktops()
                    PermissionService.openAccessibilitySettings()
                }))
            self.panel = panel
        }
        if let screen = SpaceService.screenUnderPointer, let panel {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
        }
        reload()
        // This panel accepts typing without replacing the frontmost application.
        panel?.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            await viewModel.load()
            if generation == loadGeneration { isLoading = false }
        }
    }

    private func dismiss() {
        loadTask?.cancel()
        panel?.orderOut(nil)
    }

    private func submit() {
        guard panel?.isVisible == true, !isLoading, let request = viewModel.moveRequest else { return }
        dismiss()
        Task { await desktops.moveWindow(.success(request.window), to: request.destination) }
    }
}

private final class WindowPickerPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func close() { onClose?(); super.close() }
}
