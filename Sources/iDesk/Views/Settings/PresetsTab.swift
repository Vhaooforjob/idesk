import SwiftUI

struct PresetsTab: View {
    @ObservedObject var viewModel: PresetsViewModel
    @ObservedObject var displays: DisplaysViewModel
    @State private var name = ""
    @State private var screens: PresetScreens = .unchanged
    @State private var externalID: CGDirectDisplayID?
    @State private var launchItems: [SessionLaunchItem] = []
    @State private var captureWindows = false
    @State private var webAddress = ""
    @State private var itemError: String?
    @State private var editing: WorkspacePreset?

    private func chooseItems() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !launchItems.contains(where: { $0.address == url.absoluteString }) {
            launchItems.append(SessionLaunchItem(address: url.absoluteString, name: url.lastPathComponent))
        }
    }

    var body: some View {
        Form {
            Section("Ready to Use") {
                ForEach(viewModel.suggestions) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name).font(.headline)
                            Text(preset.visibility.title + " · " + preset.screens.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Apply") { viewModel.apply(preset) }
                    }
                }
            }
            Section("Save Current Setup") {
                Text("Save the current Look and Desktop Line settings with a screen arrangement.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("Preset name", text: $name)
                Picker("Screens", selection: $screens) {
                    ForEach(PresetScreens.allCases) { Text($0.title).tag($0) }
                }
                if screens == .externalOnly {
                    Picker("External screen", selection: $externalID) {
                        Text("Choose a screen").tag(nil as CGDirectDisplayID?)
                        ForEach(displays.externals) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Toggle("Remember Open Window Layout", isOn: $captureWindows)
                Text("Window layouts match apps and titles. Apps restore their own documents; missing or ambiguous windows are reported. Moves stay on the same display.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add Apps or Folders…", action: chooseItems)
                    TextField("https://…", text: $webAddress)
                    Button("Add URL") {
                        let item = SessionLaunchItem(address: webAddress.trimmingCharacters(in: .whitespacesAndNewlines), name: webAddress)
                        guard let url = item.url, !url.isFileURL else { itemError = String(localized: "Enter an HTTP(S) URL."); return }
                        launchItems.append(item)
                        webAddress = ""
                        itemError = nil
                    }
                }
                ForEach(launchItems) { item in
                    HStack {
                        Text(item.name).lineLimit(1).help(item.address)
                        Spacer()
                        Button { launchItems.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }
                    }
                }
                if let itemError { Text(itemError).foregroundStyle(.red) }
                Button("Save Preset") {
                    Task {
                        await viewModel.saveSession(name: name, screens: screens, externalID: externalID,
                                                    launchItems: launchItems, captureWindows: captureWindows)
                        if viewModel.errorMessage == nil { name = ""; launchItems = []; captureWindows = false }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (screens == .externalOnly && externalID == nil))
            }
            if !viewModel.presets.isEmpty {
                Section("Your Presets") {
                    ForEach(viewModel.presets) { preset in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                Text(preset.visibility.title + " · " + preset.screens.title)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let session = preset.session {
                                Text("\(session.launchItems.count) items · \(session.windows.count) windows").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Apply") { viewModel.apply(preset) }
                            Button("Edit…") { editing = preset }
                            Button("Duplicate") { viewModel.duplicate(preset) }
                            Button(role: .destructive) { viewModel.remove(preset) } label: {
                                Image(systemName: "trash")
                            }.accessibilityLabel("Delete preset")
                        }
                    }
                }
            }
            if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }
            if !viewModel.failedSession.launchItems.isEmpty || !viewModel.failedSession.windows.isEmpty {
                Button("Retry Failed Items") { Task { await viewModel.retryFailed() } }
            }
        }
        .formStyle(.grouped)
        .disabled(viewModel.isApplying || viewModel.isSaving)
        .overlay(alignment: .bottom) {
            if viewModel.isApplying || viewModel.isSaving { ProgressView("Preparing workspace…").padding().background(.regularMaterial, in: Capsule()) }
        }
        .sheet(item: $editing) { preset in SessionEditor(model: viewModel, draft: preset, close: { editing = nil }) }
        .onAppear { displays.refresh() }
    }
}
