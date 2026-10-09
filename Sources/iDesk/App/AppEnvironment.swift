import AppKit
import Combine

/// Builds the app once: the services, the view models on top of them, and
/// the global shortcuts that drive them. The views are created by the app
/// delegate from these view models.
@MainActor
final class AppEnvironment {
    let settingsStore: SettingsStore
    let spaceService: SpaceService
    let thumbnailStore: ThumbnailStore
    let displayService: DisplayService
    let dialogs: DialogPresenting

    let desktops: DesktopsViewModel
    let line: DesktopLineViewModel
    let banner: NameBannerViewModel
    let menuBar: MenuBarViewModel
    let displays: DisplaysViewModel

    private let hotkeys = HotkeyService()
    private var cancellables: Set<AnyCancellable> = []

    init(dialogs: DialogPresenting) {
        settingsStore = SettingsStore()
        spaceService = SpaceService()
        thumbnailStore = ThumbnailStore()
        displayService = DisplayService()
        self.dialogs = dialogs

        desktops = DesktopsViewModel(
            spaceService: spaceService,
            thumbnailStore: thumbnailStore,
            settingsStore: settingsStore,
            switcher: SpaceSwitcher(spaces: spaceService),
            desktopManager: MissionControlService(),
            dialogs: dialogs
        )
        line = DesktopLineViewModel(desktops: desktops)
        banner = NameBannerViewModel(desktops: desktops)
        displays = DisplaysViewModel(service: displayService, dialogs: dialogs)
        menuBar = MenuBarViewModel(desktops: desktops, line: line, displays: displays, settingsStore: settingsStore, dialogs: dialogs)
    }

    func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(settingsStore: settingsStore, desktops: desktops, screens: displays)
    }

    func start() {
        PermissionService.logState()
        desktops.start()

        hotkeys.onAction = { [weak self] action in
            switch action {
            case .toggleLine: self?.line.toggle()
            case .renameCurrent: self?.desktops.renameCurrent()
            case .restoreDisplays: self?.displays.turnEverythingOn()
            }
        }
        settingsStore.$value
            .map { [HotkeyService.Action.toggleLine: $0.toggleLineHotkey, .renameCurrent: $0.renameHotkey,
                    .restoreDisplays: $0.restoreDisplaysHotkey] }
            .removeDuplicates()
            .sink { [weak self] shortcuts in self?.hotkeys.register(shortcuts) }
            .store(in: &cancellables)
    }

    /// Screens iDesk turned off come back when it quits.
    func stop() {
        displayService.turnEverythingBackOn()
    }
}
