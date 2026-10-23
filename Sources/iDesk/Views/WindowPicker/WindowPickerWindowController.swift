import AppKit
import SwiftUI

@MainActor
final class WindowPickerWindowController {
    private let desktops: DesktopsViewModel
    private let settingsStore: SettingsStore
    private let viewModel: WindowPickerViewModel
    private var panel: WindowPickerPanel?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var isLoading = false

    init(desktops: DesktopsViewModel, settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.desktops = desktops
        viewModel = WindowPickerViewModel(desktops: desktops)
    }

    func toggle() {
        if panel?.isVisible == true { dismiss(); return }
        if panel == nil {
            let panel = WindowPickerPanel(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 590),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = String(localized: "Find and Move Windows")
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.onClose = { [weak self] in self?.loadTask?.cancel() }
            self.panel = panel
        }
        if let panel {
            panel.contentView = NSHostingView(rootView: WindowPickerView(viewModel: viewModel,
                settingsStore: settingsStore,
                submit: { [weak self] in self?.submit() }, cancel: { [weak self] in self?.dismiss() },
                refresh: { [weak self] in self?.reload() }, openAccessibility: { [weak self] in
                    self?.dismiss()
                    PermissionService.requestSwitchDesktops()
                    PermissionService.openAccessibilitySettings()
                }, activate: { [weak self] in self?.activate() },
                undo: { [weak self] in
                    guard let self else { return }
                    self.dismiss()
                    Task { await self.desktops.undoLastMove() }
                }, canUndo: desktops.canUndoMove, arrange: { [weak self] layout in
                    guard let self else { return }
                    let windows = self.viewModel.selectedWindows.map(\.selection)
                    Task { await self.desktops.arrange(windows, using: layout); self.reload() }
                }, undoArrangement: { [weak self] in
                    guard let self else { return }
                    Task { await self.desktops.undoArrangement(); self.reload() }
                }))
        }
        if let screen = SpaceService.screenUnderPointer, let panel {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY - panel.frame.height / 2))
        }
        reload()
        // This panel accepts typing without replacing the frontmost application.
        panel?.makeKeyAndOrderFront(nil)
    }

    func show(desktopID: String) {
        if panel?.isVisible == true { dismiss() }
        toggle()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.viewModel.load()
            self.viewModel.desktopFilter = self.desktops.spaces.first { $0.id == desktopID }?.managedID
            self.isLoading = false
        }
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

    private func activate() {
        guard !isLoading, let selection = viewModel.selectedWindow?.selection else { return }
        dismiss()
        Task { await desktops.activateWindow(selection) }
    }

    private func submit() {
        guard panel?.isVisible == true, !isLoading, let request = viewModel.batchRequest else { return }
        dismiss()
        let follow = settingsStore.value.followMovedWindow
        Task { await desktops.moveWindows(request.windows, to: request.destination, follow: follow) }
    }
}

private final class WindowPickerPanel: NSPanel {
    var onClose: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func close() { onClose?(); super.close() }
}
