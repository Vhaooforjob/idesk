import AppKit
import Combine

@MainActor
final class PresetsViewModel: ObservableObject {
    @Published private(set) var presets: [WorkspacePreset] = []
    @Published private(set) var errorMessage: String?
    let suggestions = WorkspacePreset.suggestions
    let displays: DisplaysViewModel
    private let store: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: SettingsStore, displays: DisplaysViewModel) {
        self.store = store
        self.displays = displays
        store.$value.map(\.presets).sink { [weak self] in self?.presets = $0 }.store(in: &cancellables)
    }

    static func identity(_ id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    func save(name: String, screens: PresetScreens, externalID: CGDirectDisplayID?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var preset = WorkspacePreset(name: name, settings: store.value, screens: screens)
        if screens == .externalOnly {
            guard let id = externalID, let identity = Self.identity(id) else {
                errorMessage = String(localized: "Choose a connected external screen.")
                return
            }
            preset.externalDisplayIdentity = identity
        }
        store.value.presets.append(preset)
        errorMessage = nil
    }

    func remove(_ preset: WorkspacePreset) {
        store.value.presets.removeAll { $0.id == preset.id }
    }

    func apply(_ preset: WorkspacePreset) {
        errorMessage = nil
        displays.refresh()
        let arrangement: DisplayArrangement?
        switch preset.screens {
        case .unchanged: arrangement = nil
        case .allOn: arrangement = .allOn
        case .mainOnly: arrangement = .mainOnly
        case .externalOnly:
            guard let identity = preset.externalDisplayIdentity,
                  let display = displays.externals.first(where: { Self.identity($0.id) == identity }) else {
                errorMessage = String(localized: "The preset’s external screen is not connected. No changes were applied.")
                return
            }
            arrangement = .externalOnly(display.id)
        }
        if let arrangement, !displays.choose(arrangement) {
            errorMessage = String(localized: "The screen change was not kept. No appearance changes were applied.")
            return
        }
        preset.apply(to: &store.value)
    }
}
