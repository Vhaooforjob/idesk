import Foundation

struct SettingsArchive: Codable {
    struct Desktop: Codable, Identifiable {
        let id: String
        let name: String
        let display: String
    }
    var version = 1
    var settings: AppSettings
    var desktops: [Desktop]

    init(settings: AppSettings, spaces: [DesktopSpace]) {
        self.settings = settings
        desktops = spaces.map { Desktop(id: $0.id, name: settings.name(for: $0), display: $0.displayID) }
    }

    static func read(_ data: Data) throws -> Self {
        guard data.count <= 5_000_000 else { throw invalid() }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.version == 1, Set(archive.desktops.map(\.id)).count == archive.desktops.count else { throw invalid() }
        return archive
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Empty mappings are explicitly skipped. UUIDs are never guessed by order.
    func mapped(using mapping: [String: String], available: Set<String>) throws -> AppSettings {
        let mapping = mapping.filter { !$0.value.isEmpty }
        guard Set(mapping.values).count == mapping.count,
              Set(mapping.keys).isSubset(of: Set(desktops.map(\.id))),
              Set(mapping.values).isSubset(of: available) else { throw Self.invalid() }
        var value = settings
        value.names = [:]
        value.appearances = [:]
        value.desktopHotkeys = [:]
        value.privateDesktopIDs = []
        value.workspace.organization = [:]
        value.workspace.pinnedCommands = []
        value.workspace.recentCommands = []
        value.workspace.contextRules = []
        value.workspace.automationPaused = true
        for (old, new) in mapping {
            value.workspace.organization[new] = settings.workspace.organization[old]
            value.names[new] = settings.names[old]
            value.appearances[new] = settings.appearances[old]
            value.desktopHotkeys[new] = settings.desktopHotkeys[old]
            if settings.privateDesktopIDs.contains(old) { value.privateDesktopIDs.insert(new) }
        }
        value.windowRules = settings.windowRules.compactMap { rule in
            guard let id = mapping[rule.desktopID] else { return nil }
            var rule = rule
            rule.id = UUID().uuidString
            rule.desktopID = id
            // Importing does not immediately move existing windows.
            rule.isEnabled = false
            return rule
        }
        value.presets = settings.presets.map { preset in
            var preset = preset
            preset.id = UUID().uuidString
            let windows: [SavedWindowPlacement] = preset.session?.windows.compactMap { window in
                guard let id = mapping[window.desktopID] else { return nil }
                var window = window
                window.desktopID = id
                window.displayIdentity = nil
                return window
            } ?? []
            preset.session?.windows = windows
            return preset
        }
        return value
    }

    private static func invalid() -> WorkspaceFeatureError {
        WorkspaceFeatureError(message: String(localized: "Invalid backup, unsupported version, or duplicate desktop mapping."))
    }
}
