import AppKit
import Combine

/// The desktops and what can be done with them: their names, their
/// previews, switching and renaming. The line, the banner, the menu bar and
/// Settings all build on it.
@MainActor
final class DesktopsViewModel {
    /// A desktop the user just arrived on.
    let arrivals = PassthroughSubject<DesktopSpace, Never>()
    /// A desktop whose card should play the switch effect.
    let highlights = PassthroughSubject<String, Never>()
    /// Whether iDesk may drive Mission Control; replaced in tests.
    var hasAccessibility: () -> Bool = { PermissionService.canSwitchDesktops }

    private let spaceService: SpaceService
    private let thumbnailStore: ThumbnailStore
    private let settingsStore: SettingsStore
    private let switcher: SpaceSwitcher
    private let desktopManager: DesktopManaging
    private let dialogs: DialogPresenting
    private var lastCurrent: [String: String] = [:]
    private var previewTimer: Timer?

    /// How long to wait after a switch before taking the new desktop's
    /// picture, so the slide has finished.
    private static let settleDelay: TimeInterval = 0.9

    init(spaceService: SpaceService, thumbnailStore: ThumbnailStore, settingsStore: SettingsStore,
         switcher: SpaceSwitcher, desktopManager: DesktopManaging, dialogs: DialogPresenting) {
        self.spaceService = spaceService
        self.thumbnailStore = thumbnailStore
        self.settingsStore = settingsStore
        self.switcher = switcher
        self.desktopManager = desktopManager
        self.dialogs = dialogs
    }

    func start() {
        spaceService.onActiveSpaceChange = { [weak self] in self?.activeSpaceChanged() }
        spaceService.start()
        rememberCurrent()

        // A desktop you stay on keeps its picture fresh.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let screen = SpaceService.screenUnderPointer else { return }
                self?.refreshPreview(on: screen)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        previewTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            for screen in NSScreen.screens { self?.refreshPreview(on: screen) }
        }
    }

    // MARK: Reading

    var spaces: [DesktopSpace] { spaceService.spaces }
    var settings: AppSettings { settingsStore.value }

    /// Fires after anything a desktop card shows has changed: the Spaces,
    /// a preview, or a setting.
    var changes: AnyPublisher<Void, Never> {
        Publishers.Merge3(
            spaceService.$spaces.map { _ in () },
            thumbnailStore.$images.map { _ in () },
            settingsStore.$value.map { _ in () }
        )
        // @Published fires before the value is stored; read it a moment later.
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
    }

    var settingsChanges: AnyPublisher<AppSettings, Never> {
        settingsStore.$value.removeDuplicates().eraseToAnyPublisher()
    }

    func reload() {
        spaceService.reload()
    }

    func spaces(on screen: NSScreen?) -> [DesktopSpace] {
        spaceService.spaces(on: screen)
    }

    func currentSpace(on screen: NSScreen?) -> DesktopSpace? {
        spaceService.currentSpace(on: screen)
    }

    func name(for space: DesktopSpace) -> String {
        settings.name(for: space)
    }

    func thumbnail(for space: DesktopSpace) -> NSImage? {
        thumbnailStore.images[space.id]
    }

    /// The Spaces grouped by display, in Mission Control's order.
    var spacesByDisplay: [(displayID: String, spaces: [DesktopSpace])] {
        var order: [String] = []
        for space in spaces where !order.contains(space.displayID) { order.append(space.displayID) }
        return order.map { display in (display, spaces.filter { $0.displayID == display }) }
    }

    /// The cards to hang for a screen's desktops.
    func hangingDesktops(on screen: NSScreen) -> [HangingDesktop] {
        let value = settings
        let aspect = screen.frame.width / max(screen.frame.height, 1)
        return spaces(on: screen)
            .filter { value.showsFullScreenSpaces || $0.kind == .desktop }
            .map { space in
                HangingDesktop(
                    space: space,
                    name: value.name(for: space),
                    thumbnail: value.showsPreviews ? thumbnail(for: space) : nil,
                    aspect: aspect
                )
            }
    }

    // MARK: Switching

    func go(to space: DesktopSpace) {
        switch switcher.go(to: space) {
        case .switching:
            break
        case .alreadyThere:
            highlights.send(space.id)
        case .needsPermission:
            requestSwitchingPermission()
        case .noShortcut:
            if dialogs.confirmShortcutSettings() { PermissionService.openKeyboardShortcutSettings() }
        }
    }

    func requestSwitchingPermission() {
        guard dialogs.confirmAccessibility() else { return }
        PermissionService.requestSwitchDesktops()
        PermissionService.openAccessibilitySettings()
    }

    private func activeSpaceChanged() {
        switcher.spaceDidChange()
        let arrived = spaces.filter { $0.isCurrent && lastCurrent[$0.displayID] != $0.id }
        rememberCurrent()
        guard let space = arrived.first else { return }
        arrivals.send(space)
        highlights.send(space.id)
        if settings.playsSounds { NSSound(named: "Pop")?.play() }
        if let screen = Self.screen(for: space.displayID) ?? SpaceService.screenUnderPointer {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
                self?.refreshPreview(on: screen)
            }
        }
    }

    private func rememberCurrent() {
        lastCurrent = Dictionary(spaces.filter(\.isCurrent).map { ($0.displayID, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Naming

    func rename(_ space: DesktopSpace) {
        guard let name = dialogs.askForName(of: space, current: name(for: space)) else { return }
        settingsStore.value.setName(name, for: space)
        highlights.send(space.id)
    }

    func renameCurrent() {
        guard let space = currentSpace(on: SpaceService.screenUnderPointer) else { return }
        rename(space)
    }

    func resetName(_ space: DesktopSpace) {
        settingsStore.value.setName("", for: space)
    }

    // MARK: Adding and deleting

    /// Mission Control keeps at least one desktop per display, and the one
    /// you are on cannot be deleted from under you. Full screen apps leave
    /// full screen instead.
    func canDelete(_ space: DesktopSpace) -> Bool {
        space.kind == .desktop && !space.isCurrent
            && spaces.filter { $0.displayID == space.displayID && $0.kind == .desktop }.count > 1
    }

    /// Deletes a desktop after asking. Its windows move to another desktop.
    func delete(_ space: DesktopSpace) async {
        guard canDelete(space), dialogs.confirmDelete(desktopNamed: name(for: space)) else { return }
        guard hasAccessibility() else { return requestSwitchingPermission() }
        do {
            try await desktopManager.removeDesktop(at: space.position, on: Self.displayNumber(for: space.displayID))
            settingsStore.value.names[space.id] = nil
            reload()
        } catch {
            let howTo = String(localized: "In Mission Control, point at “\(name(for: space))” at the top of the screen and click its ✕.")
            if dialogs.offerMissionControl(String(localized: "Could not delete the desktop"), error, howTo: howTo) {
                desktopManager.openMissionControl()
            }
        }
    }

    /// Adds a desktop at the end of a display's desktops.
    func addDesktop(onDisplay displayID: String?) async {
        guard hasAccessibility() else { return requestSwitchingPermission() }
        do {
            try await desktopManager.addDesktop(on: displayID.flatMap(Self.displayNumber(for:)))
            reload()
        } catch {
            let howTo = String(localized: "In Mission Control, click + at the top right of the screen.")
            if dialogs.offerMissionControl(String(localized: "Could not add a desktop"), error, howTo: howTo) {
                desktopManager.openMissionControl()
            }
        }
    }

    /// Adds a desktop on the display under the pointer.
    func addDesktopHere() async {
        await addDesktop(onDisplay: currentSpace(on: SpaceService.screenUnderPointer)?.displayID)
    }

    // MARK: Previews

    func refreshPreview(on screen: NSScreen) {
        guard settings.showsPreviews, let space = currentSpace(on: screen) else { return }
        thumbnailStore.capture(space, on: screen) { [weak self] in
            guard let self else { return false }
            self.reload()
            return self.currentSpace(on: screen)?.id == space.id
        }
    }

    // MARK: Screens

    static func screen(for displayID: String) -> NSScreen? {
        NSScreen.screens.first { SpaceService.displayIdentifier(for: $0) == displayID }
    }

    /// The CoreGraphics number of a Spaces display identifier; nil for
    /// "Main", when every display shares the same Spaces.
    static func displayNumber(for displayID: String) -> CGDirectDisplayID? {
        screen(for: displayID)?.displayID
    }
}
