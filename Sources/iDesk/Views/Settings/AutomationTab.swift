import SwiftUI
import UniformTypeIdentifiers

struct AutomationTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var appURL: URL?
    @State private var target = ""
    @State private var title = ""
    @State private var message: String?

    var body: some View {
        Form {
            if let service = viewModel.windowRules { RuleStatusView(service: service) }
            Section("New Window Rule") {
                Text("Move new windows to a desktop without following them. Rules use the first matching app and title. Windows stay on the same display; full screen and minimized windows are excluded.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(appURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Choose Application…")) {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.applicationBundle]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK { appURL = panel.url }
                }
                TextField("Window title contains (optional)", text: $title)
                Picker("Destination Desktop", selection: $target) {
                    Text("Choose a desktop").tag("")
                    ForEach(viewModel.desktopGroups) { group in
                        ForEach(group.rows.filter { $0.space.kind == .desktop }) { row in
                            Text(group.title + " · " + viewModel.settings.name(for: row.space)).tag(row.id)
                        }
                    }
                }
                Button("Add Rule") {
                    guard let appURL, let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
                        message = String(localized: "Choose an application with a bundle identifier."); return
                    }
                    viewModel.settings.windowRules.append(WindowRule(bundleID: bundleID,
                        appName: appURL.deletingPathExtension().lastPathComponent,
                        titleContains: title.trimmingCharacters(in: .whitespacesAndNewlines), desktopID: target))
                    title = ""
                    message = nil
                }.disabled(appURL == nil || target.isEmpty)
                if let message { Text(message).foregroundStyle(.red) }
            }
            Section("Window Rules") {
                if viewModel.settings.windowRules.isEmpty { Text("No window rules yet.").foregroundStyle(.secondary) }
                ForEach($viewModel.settings.windowRules) { $rule in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(rule.appName, isOn: $rule.isEnabled)
                            Spacer()
                            Button { moveUp(rule.id) } label: { Image(systemName: "arrow.up") }
                                .disabled(viewModel.settings.windowRules.first?.id == rule.id)
                                .accessibilityLabel("Increase rule priority")
                            Button(role: .destructive) { viewModel.settings.windowRules.removeAll { $0.id == rule.id } } label: {
                                Image(systemName: "trash")
                            }.accessibilityLabel("Delete rule")
                        }
                        TextField("Window title contains (optional)", text: $rule.titleContains)
                        Picker("Destination Desktop", selection: $rule.desktopID) {
                            if !viewModel.desktopGroups.flatMap(\.rows).contains(where: { $0.id == rule.desktopID }) {
                                Text("Desktop unavailable").tag(rule.desktopID)
                            }
                            ForEach(viewModel.desktopGroups) { group in
                                ForEach(group.rows.filter { $0.space.kind == .desktop }) { row in
                                    Text(group.title + " · " + viewModel.settings.name(for: row.space)).tag(row.id)
                                }
                            }
                        }
                    }
                }
                Text("Rules apply to newly discovered windows. To reposition existing windows, use Find and Move Windows. Disabling a rule does not undo earlier moves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func moveUp(_ id: String) {
        guard let index = viewModel.settings.windowRules.firstIndex(where: { $0.id == id }), index > 0 else { return }
        viewModel.settings.windowRules.swapAt(index, index - 1)
    }

}

private struct RuleStatusView: View {
    @ObservedObject var service: WindowRuleService
    var body: some View {
        if let error = service.lastError { Text(error).foregroundStyle(.red) }
    }
}
