import AppKit
import Combine

/// Everything the Settings window edits and shows.
@MainActor
final class SettingsViewModel: ObservableObject {
    struct DesktopRow: Identifiable {
        let space: DesktopSpace
        let thumbnail: NSImage?
        var id: String { space.id }
    }

    struct DesktopGroup: Identifiable {
        let id: String
        let title: String
        let rows: [DesktopRow]
    }

    /// Edited directly by the controls; every change is saved.
    @Published var settings: AppSettings {
        didSet { if settingsStore.value != settings { settingsStore.value = settings } }
    }
    @Published private(set) var desktopGroups: [DesktopGroup] = []
    @Published private(set) var canSwitch = PermissionService.canSwitchDesktops
    @Published private(set) var canCapture = PermissionService.canCapturePreviews
    @Published private(set) var launchAtLogin = LaunchAtLoginService.isEnabled
    @Published private(set) var launchError: String?

    /// The line drawn at the top of the Look tab.
    let preview: DesktopLineViewModel
    /// The Screens tab.
    let screens: DisplaysViewModel

    private let settingsStore: SettingsStore
    private let desktops: DesktopsViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(settingsStore: SettingsStore, desktops: DesktopsViewModel, screens: DisplaysViewModel) {
        self.settingsStore = settingsStore
        self.desktops = desktops
        self.screens = screens
        settings = settingsStore.value
        preview = DesktopLineViewModel(preview: Self.sampleDesktops, settings: settingsStore.$value.eraseToAnyPublisher())

        settingsStore.$value
            .sink { [weak self] value in
                guard let self, value != self.settings else { return }
                self.settings = value
            }
            .store(in: &cancellables)
        desktops.changes
            .sink { [weak self] in self?.updateDesktopGroups() }
            .store(in: &cancellables)
        updateDesktopGroups()
    }

    // MARK: Desktops tab

    func refresh() {
        desktops.reload()
        screens.refresh()
        updateDesktopGroups()
        refreshPermissions()
    }

    func updateDesktopGroups() {
        let groups = desktops.spacesByDisplay
        desktopGroups = groups.enumerated().map { index, group in
            DesktopGroup(
                id: group.displayID,
                title: groups.count > 1 ? String(localized: "Display \(index + 1)") : String(localized: "Desktops"),
                rows: group.spaces.map { DesktopRow(space: $0, thumbnail: desktops.thumbnail(for: $0)) }
            )
        }
    }

    /// What the name field shows: the custom name, or empty for the default.
    func customName(for space: DesktopSpace) -> String {
        settings.names[space.id] ?? ""
    }

    /// Typed into the name field, kept as written; cleaned up when shown.
    func setCustomName(_ name: String, for space: DesktopSpace) {
        settings.names[space.id] = name.isEmpty ? nil : name
    }

    func go(to space: DesktopSpace) {
        desktops.go(to: space)
    }

    func canDelete(_ space: DesktopSpace) -> Bool {
        desktops.canDelete(space)
    }

    func delete(_ space: DesktopSpace) {
        Task { await desktops.delete(space) }
    }

    /// Adds a desktop on a display group of the list.
    func addDesktop(to group: DesktopGroup) {
        Task { await desktops.addDesktop(onDisplay: group.id) }
    }

    // MARK: Look tab

    func blowPreview() {
        preview.blow()
    }

    func playPreviewEffect() {
        preview.playEffect()
    }

    // MARK: General tab

    func refreshPermissions() {
        let switching = PermissionService.canSwitchDesktops
        let capture = PermissionService.canCapturePreviews
        if canSwitch != switching { canSwitch = switching }
        if canCapture != capture { canCapture = capture }
    }

    func allowSwitching() {
        desktops.requestSwitchingPermission()
        refreshPermissions()
    }

    func allowPreviews() {
        if !PermissionService.requestCapturePreviews() { PermissionService.openScreenRecordingSettings() }
        refreshPermissions()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = LaunchAtLoginService.isEnabled
    }

    /// Four made-up desktops for the preview.
    static let sampleDesktops: [HangingDesktop] = {
        let names = ["Work", "Design", "Music", "Chill"]
        return names.enumerated().map { index, name in
            HangingDesktop(
                space: DesktopSpace(id: "sample-\(index)", managedID: index, displayID: "Main", kind: .desktop,
                                    position: index, number: index + 1, ownerName: nil, isCurrent: index == 0),
                name: name,
                thumbnail: nil
            )
        }
    }()
}
