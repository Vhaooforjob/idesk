import AppKit
import SwiftUI

@MainActor
final class DesktopSearchWindowController {
    private let desktops: DesktopsViewModel
    private let model: DesktopSearchViewModel
    private var panel: SearchPanel?

    init(desktops: DesktopsViewModel) {
        self.desktops = desktops
        model = DesktopSearchViewModel(desktops: desktops)
    }

    func toggle() {
        if panel?.isVisible == true { panel?.orderOut(nil); return }
        if panel == nil {
            let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                    styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = String(localized: "Find Desktop")
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            self.panel = panel
        }
        desktops.reload()
        model.open()
        // Recreate the view so keyboard focus returns to Search after every opening.
        panel?.contentView = NSHostingView(rootView: DesktopSearchView(model: model,
            submit: { [weak self] in self?.submit() },
            cancel: { [weak self] in self?.panel?.orderOut(nil) }))
        if let screen = SpaceService.screenUnderPointer, let panel {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - panel.frame.width / 2,
                                        y: screen.visibleFrame.midY - panel.frame.height / 2))
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func submit() {
        let selectedID = model.selectedID
        model.refresh()
        guard let target = model.selection, target.id == selectedID else { return }
        panel?.orderOut(nil)
        desktops.go(to: target)
    }
}

private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct DesktopSearchView: View {
    @ObservedObject var model: DesktopSearchViewModel
    let submit: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Search desktops by name or number", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onKeyPress(.upArrow) { model.step(-1); return .handled }
                .onKeyPress(.downArrow) { model.step(1); return .handled }
                .onSubmit { submit() }
            if model.filtered.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selectedID) {
                        ForEach(model.filtered) { entry in
                            HStack(spacing: 12) {
                                Image(systemName: entry.appearance.symbol)
                                    .foregroundStyle(entry.appearance.color.color).frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text(entry.name).font(.headline)
                                    Text("\(entry.space.defaultName) · \(entry.displayName)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.space.isCurrent { Text("Current").foregroundStyle(.secondary) }
                            }
                            .padding(.vertical, 4)
                            .tag(entry.id)
                            .onTapGesture(count: 2) { model.selectedID = entry.id; submit() }
                        }
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            HStack {
                Text("↑/↓ select · Return to switch · Esc to close").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Go", action: submit).keyboardShortcut(.defaultAction).disabled(model.selection == nil)
            }
        }
        .padding(16).frame(width: 500, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onExitCommand(perform: cancel)
    }
}
