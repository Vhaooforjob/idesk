import SwiftUI
import UniformTypeIdentifiers

struct SettingsTransferView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var archive: SettingsArchive?
    @State private var mapping: [String: String] = [:]
    @State private var showingMapping = false
    @State private var message: String?

    var body: some View {
        HStack {
            Button("Export Settings…", action: export)
            Button("Import Settings…", action: load)
        }
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        Text("Backups include names, shortcuts, rules and session paths. Preview images are excluded.")
            .font(.caption).foregroundStyle(.secondary)
            .sheet(isPresented: $showingMapping) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Match Desktops").font(.title2)
                    Text("Import replaces settings. Match each saved desktop or skip it. Imported rules start disabled; sessions only run when you apply a preset.")
                    ScrollView {
                        if let archive {
                            ForEach(archive.desktops) { desktop in
                                Picker(desktop.name, selection: Binding(
                                    get: { mapping[desktop.id] ?? "" }, set: { mapping[desktop.id] = $0 }
                                )) {
                                    Text("Skip").tag("")
                                    ForEach(viewModel.desktopGroups) { group in
                                        ForEach(group.rows) { row in
                                            Text(group.title + " · " + viewModel.settings.name(for: row.space)).tag(row.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if let message { Text(message).foregroundStyle(.red) }
                    HStack {
                        Spacer()
                        Button("Cancel") { showingMapping = false }.keyboardShortcut(.cancelAction)
                        Button("Import") {
                            do {
                                guard let archive else { return }
                                try viewModel.importSettings(archive, mapping: mapping)
                                showingMapping = false
                                message = String(localized: "Settings imported.")
                            } catch { message = error.localizedDescription }
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding(20).frame(width: 560, height: 400)
            }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "iDesk-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try viewModel.exportSettings().data().write(to: url, options: .atomic)
            message = String(localized: "Settings exported.")
        } catch { message = error.localizedDescription }
    }

    private func load() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let value = try SettingsArchive.read(Data(contentsOf: url))
            viewModel.refresh()
            let current = Set(viewModel.desktopGroups.flatMap(\.rows).map(\.id))
            mapping = Dictionary(uniqueKeysWithValues: value.desktops.map { ($0.id, current.contains($0.id) ? $0.id : "") })
            archive = value
            message = nil
            showingMapping = true
        } catch { message = error.localizedDescription }
    }
}
