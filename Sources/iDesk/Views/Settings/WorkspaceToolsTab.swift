import SwiftUI

struct WorkspaceToolsTab: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var journal: OperationJournal
    @ObservedObject var updates: UpdateService
    @State private var diagnostic = ""
    var body: some View {
        Form {
            Section("Context Presets") {
                Toggle("Pause automatic presets", isOn: $model.settings.workspace.automationPaused)
                Text("Rules wait two seconds, respect cooldowns, and pause while a session is being applied. Higher priority wins. Screen changes retain their confirmation countdown.").font(.caption).foregroundStyle(.secondary)
                ForEach($model.settings.workspace.contextRules) { $rule in
                    VStack(alignment: .leading) {
                        HStack {
                            Toggle("Enabled", isOn: $rule.isEnabled)
                            Picker("Event", selection: $rule.event) {
                                ForEach(ContextPresetRule.Event.allCases, id: \.self) { event in Text(event.title).tag(event) }
                            }
                            Button(role: .destructive) { model.settings.workspace.contextRules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }
                        }
                        TextField(rule.event == .appLaunched ? "Bundle ID (empty matches any app)" : "Display UUIDs, sorted and comma-separated (optional)", text: $rule.match)
                        Picker("Preset", selection: $rule.presetID) {
                            if !model.presets.presets.contains(where: { $0.id == rule.presetID }) { Text("Preset unavailable").tag(rule.presetID) }
                            ForEach(model.presets.presets) { Text($0.name).tag($0.id) }
                        }
                        HStack {
                            Stepper("Priority: \(rule.priority)", value: $rule.priority, in: 0...100)
                            Stepper("Cooldown: \(Int(rule.cooldown)) s", value: $rule.cooldown, in: 10...3600, step: 10)
                        }
                    }
                }
                Button("Add Context Rule") {
                    guard let id = model.presets.presets.first?.id else { return }
                    model.settings.workspace.contextRules.append(ContextPresetRule(presetID: id))
                }.disabled(model.presets.presets.isEmpty)
                if let service = model.contextPresets { ContextStatus(service: service) }
            }
            Section("Updates") {
                Text("Installed version: \(updates.currentVersion)")
                HStack {
                    Button("Check for Updates") { Task { await updates.check() } }.disabled(updates.checking)
                    if updates.checking { ProgressView().controlSize(.small) }
                    if updates.release != nil { Button("Open Release on GitHub", action: updates.openRelease) }
                }
                if !updates.message.isEmpty { Text(updates.message) }
                if let release = updates.release { Text(release.tag_name).font(.headline); Text(String((release.body ?? "").prefix(8000))).textSelection(.enabled) }
                Text("Download and install releases from GitHub. Automatic installation is not configured.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                HStack {
                    Button("Refresh Diagnostics") { diagnostic = journal.diagnosticSummary }
                    Button("Copy Diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostic, forType: .string) }.disabled(diagnostic.isEmpty)
                }
                Text(diagnostic).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if !model.shortcutErrors.isEmpty { Text("Some shortcuts could not be registered. Review General and Desktops.").foregroundStyle(.orange) }
            }
            Section("Operation Results") {
                Text("Results are kept in memory. Diagnostic exports exclude window titles and user content.").font(.caption).foregroundStyle(.secondary)
                Button("Clear Results", action: journal.clear)
                ForEach(journal.entries) { entry in
                    HStack(alignment: .top) {
                        Image(systemName: entry.error == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        VStack(alignment: .leading) {
                            Text(entry.operation + " · " + entry.item)
                            Text(entry.date, style: .time).font(.caption)
                            if let error = entry.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                        }
                        Spacer()
                        if entry.retry != nil { Button("Retry") { Task { await journal.retry(entry) } }.disabled(journal.retrying != nil) }
                    }
                }
            }
        }.formStyle(.grouped).onAppear { diagnostic = journal.diagnosticSummary }
    }
}
private struct ContextStatus: View {
    @ObservedObject var service: ContextPresetService
    var body: some View { if !service.status.isEmpty { Text(service.status).font(.caption) } }
}
extension ContextPresetRule.Event {
    var title: String {
        switch self {
        case .appLaunched: String(localized: "App Launched")
        case .displayConnected: String(localized: "Display Connected")
        case .displayDisconnected: String(localized: "Display Disconnected")
        case .topologyChanged: String(localized: "Display Topology Changed")
        }
    }
}
