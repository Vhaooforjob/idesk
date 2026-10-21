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
    var showWindowPicker: (() -> Void)?
    var showDesktopSearch: (() -> Void)?
    let presets: PresetsViewModel

    private let hotkeys = HotkeyService()
    private var cancellables: Set<AnyCancellable> = []

    init(dialogs: DialogPresenting) {
        settingsStore = SettingsStore()
        spaceService = SpaceService()
        thumbnailStore = ThumbnailStore(storesOnDisk: settingsStore.value.storesPreviewsOnDisk)
        displayService = DisplayService()
        self.dialogs = dialogs

        let switcher = SpaceSwitcher(spaces: spaceService)
        desktops = DesktopsViewModel(
            spaceService: spaceService,
            thumbnailStore: thumbnailStore,
            settingsStore: settingsStore,
            switcher: switcher,
            desktopManager: MissionControlService(),
            dialogs: dialogs
        )
        switcher.onFailure = { [weak desktops] space in desktops?.switchFailed(to: space) }
        line = DesktopLineViewModel(desktops: desktops)
        banner = NameBannerViewModel(desktops: desktops)
        displays = DisplaysViewModel(service: displayService, dialogs: dialogs)
        presets = PresetsViewModel(store: settingsStore, displays: displays)
        menuBar = MenuBarViewModel(desktops: desktops, line: line, displays: displays, settingsStore: settingsStore, dialogs: dialogs, presets: presets)
    }

    func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(settingsStore: settingsStore, desktops: desktops, screens: displays, hotkeys: hotkeys, presets: presets)
    }

    func start() {
        PermissionService.logState()
        desktops.start()
        settingsStore.$value.map(\.storesPreviewsOnDisk).removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                do { try self.thumbnailStore.setStoresOnDisk(enabled) }
                catch { self.dialogs.showError(String(localized: "Could not clear preview cache"), error) }
            }.store(in: &cancellables)

        hotkeys.onAction = { [weak self] action in
            switch action {
            case .toggleLine: self?.line.toggle()
            case .renameCurrent: self?.desktops.renameCurrent()
            case .restoreDisplays: self?.displays.turnEverythingOn()
            case .moveWindow: self?.showWindowPicker?()
            case .searchDesktops: self?.showDesktopSearch?()
            case .previousDesktop: self?.desktops.goToPreviousDesktop()
            }
        }
        settingsStore.$value
            .map { HotkeyService.shortcuts(in: $0) }
            .removeDuplicates()
            .sink { [weak self] shortcuts in self?.hotkeys.register(shortcuts) }
            .store(in: &cancellables)
    }

    /// Screens iDesk turned off come back when it quits.
    func stop() {
        displayService.turnEverythingBackOn()
        try? settingsStore.saveNow()
    }
}
