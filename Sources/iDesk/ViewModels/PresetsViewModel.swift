import AppKit
import Combine

@MainActor
final class PresetsViewModel: ObservableObject {
    @Published private(set) var presets: [WorkspacePreset] = []
    @Published private(set) var errorMessage: String?
    let suggestions = WorkspacePreset.suggestions
    let displays: DisplaysViewModel
    @Published private(set) var isApplying = false
    @Published private(set) var isSaving = false
    var onSessionError: ((String) -> Void)?
    let sessions: WorkspaceSessionService?
    @Published private(set) var failedSession = WorkspaceSession()
    private var applyTask: Task<Void, Never>?
    private var lastAppliedPresetID: String?
    private let store: SettingsStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: SettingsStore, displays: DisplaysViewModel, sessions: WorkspaceSessionService? = nil) {
        self.store = store
        self.sessions = sessions
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

    func saveSession(name: String, screens: PresetScreens, externalID: CGDirectDisplayID?,
                     launchItems: [SessionLaunchItem], captureWindows: Bool) async {
        guard !isSaving, !isApplying else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            guard launchItems.allSatisfy({ $0.url != nil }) else {
                throw WorkspaceFeatureError(message: String(localized: "Use a file, folder, application, or HTTP(S) URL."))
            }
            var session = WorkspaceSession(launchItems: launchItems)
            if captureWindows {
                guard let sessions else { throw WindowMoveError.unavailable }
                session = try await sessions.capture(launchItems: launchItems)
            }
            let count = store.value.presets.count
            save(name: name, screens: screens, externalID: externalID)
            if store.value.presets.count > count { store.value.presets[count].session = session }
        } catch { errorMessage = error.localizedDescription }
    }

    var desktopOptions: [DesktopSpace] { sessions?.desktops.spaces.filter { $0.kind == .desktop } ?? [] }
    func desktopName(_ space: DesktopSpace) -> String { store.value.name(for: space) }
    func update(_ preset: WorkspacePreset) {
        guard !isApplying, !isSaving, !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let index = store.value.presets.firstIndex(where: { $0.id == preset.id }) else { return }
        var preset = preset
        if var session = preset.session {
            session.windows = session.windows.map { saved in
                var saved = saved
                if let target = desktopOptions.first(where: { $0.id == saved.desktopID }) { saved.displayIdentity = target.displayID }
                return saved
            }
            preset.session = session
        }
        store.value.presets[index] = preset
        // Only repair failures from the preset that produced them.
        if lastAppliedPresetID == preset.id {
            failedSession.windows = failedSession.windows.compactMap { old in preset.session?.windows.first { $0.id == old.id } }
            failedSession.launchItems = failedSession.launchItems.compactMap { old in preset.session?.launchItems.first { $0.id == old.id } }
        }

    }
    func duplicate(_ preset: WorkspacePreset) {
        var copy = preset
        copy.id = UUID().uuidString
        if var session = copy.session {
            session.windows = session.windows.map { window in var value = window; value.id = UUID().uuidString; return value }
            session.launchItems = session.launchItems.map { item in var value = item; value.id = UUID().uuidString; return value }
            copy.session = session
        }
        copy.name += " " + String(localized: "Copy")
        store.value.presets.append(copy)
    }
    func applyAndWait(_ preset: WorkspacePreset) async throws {
        guard !isApplying, !isSaving else { throw WorkspaceFeatureError(message: String(localized: "A workspace operation is already running.")) }
        apply(preset)
        await applyTask?.value
        if let errorMessage { throw WorkspaceFeatureError(message: errorMessage) }
    }
    func retryFailed() async {
        guard !isApplying, let sessions else { return }
        isApplying = true
        let errors = await sessions.restore(failedSession, retrying: true)
        failedSession = sessions.failedSession
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        isApplying = false
    }

    func remove(_ preset: WorkspacePreset) {
        store.value.presets.removeAll { $0.id == preset.id }
        store.value.workspace.contextRules.removeAll { $0.presetID == preset.id }
        store.value.workspace.pinnedCommands.remove("preset:" + preset.id)
        if lastAppliedPresetID == preset.id { failedSession = WorkspaceSession() }
    }

    func apply(_ preset: WorkspacePreset) {
        guard !isApplying, !isSaving else { return }
        errorMessage = nil
        applyTask = nil
        failedSession = WorkspaceSession()
        lastAppliedPresetID = preset.id
        isApplying = true
        defer { if applyTask == nil { isApplying = false } }
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
        if let session = preset.session, !session.launchItems.isEmpty || !session.windows.isEmpty {
            guard let sessions else { errorMessage = WindowMoveError.unavailable.localizedDescription; return }
            isApplying = true
            applyTask = Task { [weak self] in
                let errors = await sessions.restore(session)
                guard let self else { return }
                self.failedSession = sessions.failedSession
                self.isApplying = false
                if !errors.isEmpty {
                    let message = errors.joined(separator: "\n")
                    self.errorMessage = message
                    self.onSessionError?(message)
                }
            }
        }
    }
}
