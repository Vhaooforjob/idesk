import SwiftUI

struct SessionEditor: View {
    @ObservedObject var model: PresetsViewModel
    @State var draft: WorkspacePreset
    let close: () -> Void
    @State private var candidates: [WindowCandidate] = []
    @State private var error: String?
    @State private var selections: [String: WindowSelection] = [:]
    private var session: Binding<WorkspaceSession> { Binding(get: { draft.session ?? WorkspaceSession() }, set: { draft.session = $0 }) }
    var body: some View {
        VStack(alignment: .leading) {
            Text("Edit and Repair Preset").font(.title2)
            TextField("Preset name", text: $draft.name)
            Text("Review targets and launch addresses before saving. Selecting a live window resolves ambiguity for this run; the saved match remains app and title.").font(.caption).foregroundStyle(.secondary)
            Form {
                Picker("Screens", selection: $draft.screens) { ForEach(PresetScreens.allCases) { Text($0.title).tag($0) } }
                if draft.screens == .externalOnly {
                    Picker("External screen", selection: $draft.externalDisplayIdentity) {
                        Text("Choose a screen").tag(nil as String?)
                        ForEach(model.displays.externals) { screen in Text(screen.name).tag(PresetsViewModel.identity(screen.id)) }
                    }
                }
                ForEach(session.launchItems) { $item in
                    HStack {
                        TextField("Name", text: $item.name).frame(width: 110)
                        TextField("Address", text: $item.address)
                        Button { draft.session?.launchItems.removeAll { $0.id == item.id } } label: { Image(systemName: "minus.circle") }
                    }
                }
                Button("Add Launch Item") { if draft.session == nil { draft.session = WorkspaceSession() }; draft.session?.launchItems.append(SessionLaunchItem(address: "", name: "")) }
                ForEach(session.windows) { $saved in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(saved.bundleID).font(.caption)
                            Spacer()
                            Button { draft.session?.windows.removeAll { $0.id == saved.id } } label: { Image(systemName: "trash") }
                        }
                        TextField("Window title", text: $saved.title)
                        Picker("Target Desktop", selection: $saved.desktopID) {
                            if !model.desktopOptions.contains(where: { $0.id == saved.desktopID }) { Text("Desktop unavailable").tag(saved.desktopID) }
                            ForEach(model.desktopOptions) { Text(model.desktopName($0)).tag($0.id) }
                        }
                        Menu("Choose Matching Window") {
                            Button("Match automatically") { selections[saved.id] = nil }
                            ForEach(candidates.filter { $0.bundleID == saved.bundleID && !$0.isMinimized }) { window in
                                Button(window.title + " · " + window.desktopName) {
                                    saved.title = window.title
                                    selections[saved.id] = window.selection
                                }
                            }
                        }
                        if let frame = saved.normalizedFrame, AdaptiveWindowFrame.valid(frame), abs(frame.minX) < 1000, abs(frame.minY) < 1000, frame.width < 1000, frame.height < 1000 { Text("Position: \(Int(frame.minX * 100))%, \(Int(frame.minY * 100))% · Size: \(Int(frame.width * 100))% × \(Int(frame.height * 100))%").font(.caption) }
                    }.padding(.vertical, 6)
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Refresh Windows") { Task { await refresh() } }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save Changes") {
                    guard draft.session?.launchItems.allSatisfy({ $0.url != nil }) != false else { error = String(localized: "Use a file, folder, application, or HTTP(S) URL."); return }
                    for saved in draft.session?.windows ?? [] { model.sessions?.selections[saved.id] = selections[saved.id] }
                    model.update(draft); close()
                }.keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 660, height: 560).background(Color(nsColor: .windowBackgroundColor)).task { selections = model.sessions?.selections ?? [:]; await refresh() }
    }
    private func refresh() async {
        do { model.sessions?.desktops.reload(); candidates = try await model.sessions?.desktops.windowsForMove() ?? []; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
