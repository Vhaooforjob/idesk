import AppKit
import SwiftUI
import Combine

@MainActor
final class CommandPaletteModel: ObservableObject {
    struct Entry: Identifiable {
        enum Kind { case desktop, preset, window, action }
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let kind: Kind
        let run: () async throws -> Void
    }
    @Published var query = ""
    @Published var group = ""
    @Published var favoritesOnly = false
    @Published var selectedID: String?
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    @Published private(set) var pinned: Set<String> = []
    let environment: AppEnvironment
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = 0
    init(environment: AppEnvironment) {
        self.environment = environment
        environment.settingsStore.$value.sink { [weak self] in self?.pinned = $0.workspace.pinnedCommands }.store(in: &subscriptions)
    }
    var groups: [String] { Array(Set(environment.settingsStore.value.workspace.organization.values.map(\.group).filter { !$0.isEmpty })).sorted() }
    var filtered: [Entry] {
        Self.filter(entries, query: query, group: group, favoritesOnly: favoritesOnly,
                    settings: environment.settingsStore.value, visitedDesktopIDs: environment.desktops.recentDesktopIDs)
    }
    static func filter(_ entries: [Entry], query: String, group: String, favoritesOnly: Bool,
                       settings: AppSettings, visitedDesktopIDs: [String]) -> [Entry] {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: Entry.Kind?
        if text.hasPrefix(">") { kind = .preset; text.removeFirst() }
        else if text.hasPrefix("@") { kind = .window; text.removeFirst() }
        else { kind = nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pins = settings.workspace.pinnedCommands
        let recent = settings.workspace.recentCommands
        let visited = visitedDesktopIDs.map { "desktop:" + $0 }
        return entries.filter { entry in
            let organization = settings.workspace.organization[String(entry.id.dropFirst("desktop:".count))] ?? DesktopOrganization()
            return (kind == nil || entry.kind == kind) && (text.isEmpty || (entry.title + " " + entry.detail).localizedStandardContains(text)) &&
                (group.isEmpty || (entry.kind == .desktop && organization.group == group)) &&
                (!favoritesOnly || pins.contains(entry.id) || (entry.kind == .desktop && organization.favorite))
        }.sorted { lhs, rhs in
            func rank(_ entry: Entry) -> Int {
                let favorite = entry.kind == .desktop && settings.workspace.organization[String(entry.id.dropFirst(8))]?.favorite == true
                if pins.contains(entry.id) || favorite { return -100 }
                if let i = recent.firstIndex(of: entry.id) { return i }
                if let i = visited.firstIndex(of: entry.id) { return 30 + i }
                return 100
            }
            let a = rank(lhs), b = rank(rhs)
            return a == b ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : a < b
        }
    }
    func togglePin(_ id: String) {
        if pinned.contains(id) { environment.settingsStore.value.workspace.pinnedCommands.remove(id) }
        else { environment.settingsStore.value.workspace.pinnedCommands.insert(id) }
    }
    func step(_ offset: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == selectedID } ?? 0
        selectedID = list[min(max(index + offset, 0), list.count - 1)].id
    }
    func load() async {
        generation += 1
        let token = generation
        isLoading = true; error = nil
        defer { if token == generation { isLoading = false } }
        let env = environment
        env.desktops.reload()
        var result = env.desktops.spaces.filter { $0.kind == .desktop || env.settingsStore.value.showsFullScreenSpaces }.map { space in
            let metadata = env.settingsStore.value.workspace.organization[space.id] ?? DesktopOrganization()
            return Entry(id: "desktop:" + space.id, title: env.desktops.name(for: space),
                         detail: space.defaultName + " · " + metadata.group + " " + metadata.tags,
                         symbol: metadata.favorite ? "star.fill" : "rectangle.on.rectangle", kind: .desktop,
                         run: { try await env.desktops.goAndWait(to: space.id) })
        }
        result += env.presets.presets.map { preset in
            Entry(id: "preset:" + preset.id, title: preset.name, detail: String(localized: "Preset"), symbol: "slider.horizontal.3", kind: .preset,
                  run: { try await env.presets.applyAndWait(preset) })
        }
        func action(_ id: String, _ title: String, _ symbol: String, _ run: @escaping () async throws -> Void) {
            result.append(Entry(id: "action:" + id, title: title, detail: String(localized: "Action"), symbol: symbol, kind: .action, run: run))
        }
        action("line", String(localized: "Show or hide the line"), "rectangle.topthird.inset.filled") { env.line.toggle() }
        action("restore", String(localized: "Turn every screen back on"), "display.2") { try env.restoreDisplaysAndVerify() }
        action("picker", String(localized: "Find and Move Windows"), "macwindow") { env.showWindowPicker?() }
        action("undo", String(localized: "Undo Window Move"), "arrow.uturn.backward") { await env.desktops.undoLastMove() }
        action("undoLayout", String(localized: "Undo Arrangement"), "arrow.uturn.backward") { await env.desktops.undoArrangement() }
        action("settings", String(localized: "Settings…"), "gearshape") { env.showSettings?() }
        entries = result
        do {
            let windows = try await env.desktops.windowsForMove()
            try Task.checkCancellation()
            guard token == generation else { return }
            result += windows.compactMap { window in
                guard let source = env.desktops.spaces.first(where: { $0.managedID == window.selection.sourceSpaceID }),
                      !env.settingsStore.value.privateDesktopIDs.contains(source.id) else { return nil }
                return Entry(id: "window:\(window.selection.processID):\(window.id)", title: window.title,
                             detail: window.appName + " · " + window.desktopName + (window.isMinimized ? " · " + String(localized: "Minimized") : ""),
                             symbol: "macwindow", kind: .window, run: { try await env.desktops.activateWindowAndWait(window.selection) })
            }
            entries = result
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
        selectedID = filtered.first?.id
    }
    func execute() async -> Bool {
        guard !isRunning, let entry = filtered.first(where: { $0.id == selectedID }) else { return false }
        isRunning = true; error = nil
        defer { isRunning = false }
        do {
            try await entry.run()
            var recent = environment.settingsStore.value.workspace.recentCommands
            recent.removeAll { $0 == entry.id }; recent.insert(entry.id, at: 0)
            // Window IDs are transient. Do not persist their titles or IDs.
            environment.settingsStore.value.workspace.recentCommands = Array(recent.filter { !$0.hasPrefix("window:") }.prefix(30))
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

@MainActor
final class CommandPaletteController {
    let model: CommandPaletteModel
    private var panel: PalettePanel?
    private var task: Task<Void, Never>?
    init(environment: AppEnvironment) { model = CommandPaletteModel(environment: environment) }
    func toggle() {
        if panel?.isVisible == true { close(); return }
        let panel = panel ?? PalettePanel(contentRect: CGRect(x: 0, y: 0, width: 660, height: 500), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.title = String(localized: "Command Palette")
        panel.isReleasedWhenClosed = false; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        model.query = ""; model.group = ""; model.favoritesOnly = false
        panel.contentView = NSHostingView(rootView: CommandPaletteView(model: model, close: { [weak self] in self?.close() }))
        panel.center(); panel.makeKeyAndOrderFront(nil)
        task?.cancel(); task = Task { await model.load() }
    }
    private func close() { task?.cancel(); panel?.orderOut(nil) }
}
private final class PalettePanel: NSPanel { override var canBecomeKey: Bool { true } }

private struct CommandPaletteView: View {
    @ObservedObject var model: CommandPaletteModel
    let close: () -> Void
    @FocusState private var focused: Bool
    private func submit() { Task { if await model.execute() { close() } } }
    var body: some View {
        VStack(spacing: 10) {
            TextField("Search desktops, windows, actions · > presets · @ apps", text: $model.query)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit(submit)
                .onKeyPress(.upArrow) { model.step(-1); return .handled }
                .onKeyPress(.downArrow) { model.step(1); return .handled }
            HStack {
                Picker("Group", selection: $model.group) {
                    Text("All").tag("")
                    ForEach(model.groups, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Favorites", isOn: $model.favoritesOnly).toggleStyle(.checkbox)
                if model.isLoading || model.isRunning { ProgressView().controlSize(.small) }
            }
            List(selection: $model.selectedID) {
                ForEach(model.filtered) { entry in
                    HStack {
                        Image(systemName: entry.symbol).frame(width: 24)
                        VStack(alignment: .leading) { Text(entry.title); Text(entry.detail).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if entry.kind != .window {
                            Button { model.togglePin(entry.id) } label: { Image(systemName: model.pinned.contains(entry.id) ? "pin.fill" : "pin") }.buttonStyle(.borderless)
                        }
                    }.tag(entry.id).contentShape(Rectangle()).onTapGesture(count: 2) { model.selectedID = entry.id; submit() }
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Text("↑/↓ · Return · Esc").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Run", action: submit).disabled(model.selectedID == nil || model.isRunning) }
        }.padding(16).frame(width: 660, height: 500)
        .onChange(of: model.query) { _, _ in model.selectedID = model.filtered.first?.id }
        .onChange(of: model.group) { _, _ in model.selectedID = model.filtered.first?.id }
        .onChange(of: model.favoritesOnly) { _, _ in model.selectedID = model.filtered.first?.id }
        .onAppear { focused = true }.onExitCommand(perform: close)
    }
}
