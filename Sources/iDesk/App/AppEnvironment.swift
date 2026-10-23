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
    let screenTuning: ScreenTuningViewModel
    var showWindowPicker: (() -> Void)?
    var showDesktopSearch: (() -> Void)?
    let presets: PresetsViewModel
    let windowRules: WindowRuleService
    let contextPresets: ContextPresetService
    let updates = UpdateService()
    var showSettings: (() -> Void)?
    static weak var active: AppEnvironment?

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
        screenTuning = ScreenTuningViewModel(displays: displays, settingsStore: settingsStore, system: LiveScreenTuningSystem(), dialogs: dialogs)
        presets = PresetsViewModel(store: settingsStore, displays: displays, sessions: WorkspaceSessionService(desktops: desktops))
        windowRules = WindowRuleService(store: settingsStore, desktops: desktops, suspended: { [weak presets] in
            presets?.isApplying == true || presets?.isSaving == true
        })
        contextPresets = ContextPresetService(store: settingsStore, presets: presets, journal: desktops.journal)
        presets.onSessionError = { [dialogs] message in
            dialogs.showError(String(localized: "Some session items could not be restored"), WorkspaceFeatureError(message: message))
        }
        menuBar = MenuBarViewModel(desktops: desktops, line: line, displays: displays, settingsStore: settingsStore, dialogs: dialogs, presets: presets, tuning: screenTuning)
    }

    func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(settingsStore: settingsStore, desktops: desktops, screens: displays, hotkeys: hotkeys, presets: presets, windowRules: windowRules, contextPresets: contextPresets, updates: updates, tuning: screenTuning)
    }

    func start() {
        Self.active = self
        PermissionService.logState()
        desktops.start()
        windowRules.start()
        contextPresets.start()
        screenTuning.start()
        WorkspaceShortcuts.updateAppShortcutParameters()
        settingsStore.$value.map(\.storesPreviewsOnDisk).removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                do { try self.thumbnailStore.setStoresOnDisk(enabled) }
                catch { self.dialogs.showError(String(localized: "Could not clear preview cache"), error) }
            }.store(in: &cancellables)

        settingsStore.$value.map(\.privateDesktopIDs).removeDuplicates()
            .sink { [weak self] ids in
                guard let self else { return }
                do { try self.thumbnailStore.setPrivateSpaces(ids) }
                catch { self.dialogs.showError(String(localized: "Could not clear private previews"), error) }
            }.store(in: &cancellables)
        settingsStore.$saveError.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] message in
                self?.dialogs.showError(String(localized: "Settings could not be saved"), WorkspaceFeatureError(message: message))
            }.store(in: &cancellables)

        hotkeys.onAction = { [weak self] action in
            switch action {
            case .toggleLine: self?.line.toggle()
            case .renameCurrent: self?.desktops.renameCurrent()
            case .restoreDisplays: self?.displays.turnEverythingOn()
            case .moveWindow: self?.showWindowPicker?()
            case .searchDesktops: self?.showDesktopSearch?()
            case .previousDesktop: self?.desktops.goToPreviousDesktop()
            case .undoMove: Task { await self?.desktops.undoLastMove() }
            case .brightnessUp: self?.screenTuning.nudgeBrightness(by: ScreenTuningViewModel.keyStep, near: SpaceService.screenUnderPointer?.displayID)
            case .brightnessDown: self?.screenTuning.nudgeBrightness(by: -ScreenTuningViewModel.keyStep, near: SpaceService.screenUnderPointer?.displayID)
            case .toggleNightShift: self?.screenTuning.toggleNightShift()
            case .desktop(let id):
                self?.desktops.reload()
                if let space = self?.desktops.spaces.first(where: { $0.id == id }) { self?.desktops.go(to: space) }
            }
        }
        settingsStore.$value
            .map { HotkeyService.shortcuts(in: $0) }
            .removeDuplicates()
            .sink { [weak self] shortcuts in self?.hotkeys.register(shortcuts) }
            .store(in: &cancellables)
    }

    func restoreDisplaysAndVerify() throws {
        try displayService.recoverAll()
        displayService.refresh()
        guard displayService.displays.allSatisfy(\.isEnabled) else { throw DisplayError.cannotTurnOff }
    }

    /// Screens iDesk turned off come back when it quits.
    func stop() {
        contextPresets.stop()
        windowRules.stop()
        screenTuning.stop()
        displayService.turnEverythingBackOn()
        try? settingsStore.saveNow()
    }
}
