import AppIntents

@MainActor
private func runningWorkspace() async throws -> AppEnvironment {
    for _ in 0..<50 {
        if let environment = AppEnvironment.active { return environment }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw WorkspaceFeatureError(message: String(localized: "Open iDesk and try again."))
}

struct DesktopEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Desktop")
    static var defaultQuery = DesktopEntityQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct DesktopEntityQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [DesktopEntity] {
        let settings = AppEnvironment.active?.settingsStore.value ?? SettingsStore.readForQueries()
        let spaces = SpaceService.read()
        return spaces.filter { $0.kind == .desktop }.map { DesktopEntity(id: $0.id, name: settings.name(for: $0)) }
    }
    func entities(for identifiers: [String]) async throws -> [DesktopEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func entities(matching string: String) async throws -> [DesktopEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}
struct PresetEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace Preset")
    static var defaultQuery = PresetEntityQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct PresetEntityQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [PresetEntity] {
        let settings = AppEnvironment.active?.settingsStore.value ?? SettingsStore.readForQueries()
        return settings.presets.map { PresetEntity(id: $0.id, name: $0.name) }
    }
    func entities(for identifiers: [String]) async throws -> [PresetEntity] { try await suggestedEntities().filter { identifiers.contains($0.id) } }
    func entities(matching string: String) async throws -> [PresetEntity] { try await suggestedEntities().filter { $0.name.localizedStandardContains(string) } }
}
struct SwitchDesktopIntent: AppIntent {
    static var title: LocalizedStringResource = "Switch Desktop"
    static var openAppWhenRun = true
    @Parameter(title: "Desktop") var desktop: DesktopEntity
    static var parameterSummary: some ParameterSummary { Summary("Switch to \(\.$desktop)") }
    @MainActor func perform() async throws -> some IntentResult {
        let env = try await runningWorkspace()
        try await env.desktops.goAndWait(to: desktop.id)
        return .result()
    }
}
struct ApplyWorkspacePresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Apply Workspace Preset"
    static var openAppWhenRun = true
    @Parameter(title: "Preset") var preset: PresetEntity
    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$preset)") }
    @MainActor func perform() async throws -> some IntentResult {
        let env = try await runningWorkspace()
        guard let value = env.presets.presets.first(where: { $0.id == preset.id }) else { throw WorkspaceFeatureError(message: String(localized: "Preset unavailable")) }
        try await env.presets.applyAndWait(value)
        return .result()
    }
}
struct ToggleDesktopLineIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Desktop Line"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        let env = try await runningWorkspace()
        env.line.toggle()
        return .result()
    }
}
struct RestoreDisplaysIntent: AppIntent {
    static var title: LocalizedStringResource = "Restore Displays"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        let env = try await runningWorkspace()
        try env.restoreDisplaysAndVerify()
        return .result()
    }
}
struct WorkspaceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDesktopLineIntent(), phrases: ["Toggle desktop line in \(.applicationName)"], shortTitle: "Toggle Desktop Line", systemImageName: "rectangle.topthird.inset.filled")
        AppShortcut(intent: RestoreDisplaysIntent(), phrases: ["Restore displays in \(.applicationName)"], shortTitle: "Restore Displays", systemImageName: "display.2")
        AppShortcut(intent: SwitchDesktopIntent(), phrases: ["Switch desktop in \(.applicationName)"], shortTitle: "Switch Desktop", systemImageName: "rectangle.on.rectangle")
        AppShortcut(intent: ApplyWorkspacePresetIntent(), phrases: ["Apply workspace preset in \(.applicationName)"], shortTitle: "Apply Preset", systemImageName: "slider.horizontal.3")
    }
}
