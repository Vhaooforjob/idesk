import AppKit
import Combine

/// What the menu bar item shows: the current desktop's name, and a menu of
/// desktops and options. The menu is rebuilt from it each time it opens.
@MainActor
final class MenuBarViewModel: ObservableObject {
    struct DesktopEntry {
        let space: DesktopSpace
        let title: String
    }

    struct DesktopSection {
        /// Only set when there is more than one display.
        let title: String?
        let entries: [DesktopEntry]
    }

    struct Choice {
        let title: String
        let symbol: String?
        let isSelected: Bool
        var isEnabled = true
        let select: () -> Void
    }

    struct ChoiceGroup {
        let title: String
        let choices: [Choice]
    }

    @Published private(set) var title = ""
    /// The current desktop's full name, for the tooltip and VoiceOver, even
    /// when the title shows only the icon or is shortened.
    @Published private(set) var currentName = ""
    /// The longest title the menu bar item shows before cutting it with "…".
    nonisolated static let titleLimit = 24

    let presets: PresetsViewModel
    @Published private(set) var appearance = DesktopAppearance()
    private let desktops: DesktopsViewModel
    private let line: DesktopLineViewModel
    private let displays: DisplaysViewModel
    let tuning: ScreenTuningViewModel?
    private let settingsStore: SettingsStore
    private let dialogs: DialogPresenting
    private var cancellables: Set<AnyCancellable> = []
    private var windowSelection: Result<WindowSelection, Error> = .failure(WindowMoveError.noWindow)

    init(desktops: DesktopsViewModel, line: DesktopLineViewModel, displays: DisplaysViewModel,
         settingsStore: SettingsStore, dialogs: DialogPresenting, presets: PresetsViewModel? = nil,
         tuning: ScreenTuningViewModel? = nil) {
        self.tuning = tuning
        self.presets = presets ?? PresetsViewModel(store: settingsStore, displays: displays)
        self.desktops = desktops
        self.line = line
        self.displays = displays
        self.settingsStore = settingsStore
        self.dialogs = dialogs
        desktops.changes
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    // MARK: Title

    func updateTitle() {
        let current = desktops.currentSpace(on: NSScreen.main ?? SpaceService.screenUnderPointer)
        if let current {
            appearance = settingsStore.value.appearances[current.id] ?? DesktopAppearance()
        }
        let fresh = Self.title(for: current, settings: settingsStore.value)
        if fresh != title { title = fresh }
        let name = current.map { settingsStore.value.name(for: $0) } ?? ""
        if name != currentName { currentName = name }
    }

    /// A long name would push the item into the notch or over other menu
    /// bar icons, so the menu bar shows it cut and the tooltip shows it all.
    nonisolated static func shortened(_ title: String, limit: Int = titleLimit) -> String {
        guard limit > 1, title.count > limit else { return title }
        return String(title.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func title(for space: DesktopSpace?, settings: AppSettings) -> String {
        guard let space else { return "" }
        let name = settings.name(for: space)
        switch settings.menuBarTitle {
        case .icon: return ""
        case .name: return name
        case .numberAndName:
            guard let number = space.number, name != space.defaultName else { return name }
            return "\(number) · \(name)"
        }
    }

    // MARK: Menu content

    /// Re-reads the Spaces just before the menu opens.
    func refresh() {
        windowSelection = desktops.captureWindowForMove()
        desktops.reload()
        displays.refresh()
        if let tuning {
            tuning.refreshNightShift()
            Task { await tuning.reload() }
        }
        updateTitle()
    }

    var sections: [DesktopSection] {
        let groups = desktops.spacesByDisplay
        return groups.enumerated().map { index, group in
            DesktopSection(
                title: groups.count > 1 ? String(localized: "Display \(index + 1)") : nil,
                entries: group.spaces.map { space in
                    let number = space.number.map { "\($0)  " } ?? "⤢  "
                    return DesktopEntry(space: space, title: number + desktops.name(for: space))
                }
            )
        }
    }

    /// Desktops that can be deleted: not the current one, not the last one
    /// on a display.
    var deletableDesktops: [DesktopEntry] {
        sections.flatMap(\.entries).filter { desktops.canDelete($0.space) }
    }

    var moveWindowGroup: ChoiceGroup {
        let selection = windowSelection
        return ChoiceGroup(title: String(localized: "Move Window to Desktop"), choices:
            desktops.windowMoveDestinations(for: selection).map { space in
                Choice(title: "\(space.number ?? space.position + 1)  \(desktops.name(for: space))",
                       symbol: "macwindow", isSelected: false) { [weak self] in
                    guard let self else { return }
                    Task { await self.desktops.moveWindow(selection, to: space) }
                }
            }
        )
    }

    /// The Screens submenu: what the screens show, and each screen on or
    /// off. Nil with a single screen.
    var screenGroups: (arrangements: ChoiceGroup, screens: ChoiceGroup, canTurnAllOn: Bool)? {
        guard displays.hasSeveralDisplays, displays.canTurnOff else { return nil }
        let arrangements = ChoiceGroup(
            title: String(localized: "Screens"),
            choices: displays.arrangements.map { arrangement in
                Choice(title: displays.title(for: arrangement), symbol: arrangement.symbol,
                       isSelected: arrangement == displays.arrangement) { [weak self] in
                    self?.displays.choose(arrangement)
                }
            }
        )
        let screens = ChoiceGroup(
            title: String(localized: "Turn Screens On or Off"),
            choices: displays.displays.map { display in
                Choice(title: display.name, symbol: display.isBuiltin ? "laptopcomputer" : "display",
                       isSelected: display.isEnabled, isEnabled: displays.canToggle(display)) { [weak self] in
                    self?.displays.setEnabled(display, !display.isEnabled)
                }
            }
        )
        return (arrangements, screens, displays.hasScreensOff)
    }

    func appearance(for space: DesktopSpace) -> DesktopAppearance { settingsStore.value.appearances[space.id] ?? DesktopAppearance() }
    var canUndoMove: Bool { desktops.canUndoMove }
    func undoMove() { Task { await desktops.undoLastMove() } }
    var undoShortcut: String { settingsStore.value.undoMoveHotkey }
    func desktopShortcut(_ space: DesktopSpace) -> String { settingsStore.value.desktopHotkeys[space.id] ?? "" }
    func previousDesktop() { desktops.goToPreviousDesktop() }
    var searchShortcut: String { settingsStore.value.searchDesktopsHotkey }
    var previousShortcut: String { settingsStore.value.previousDesktopHotkey }
    func applyPreset(_ preset: WorkspacePreset) {
        presets.apply(preset)
        if let message = presets.errorMessage {
            dialogs.showError(String(localized: "Could not apply preset"), NSError(domain: "iDesk", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }

    var needsSwitchingPermission: Bool { !PermissionService.canSwitchDesktops }
    var restoreDisplaysShortcut: String { settingsStore.value.restoreDisplaysHotkey }
    var renameShortcut: String { settingsStore.value.renameHotkey }
    var moveWindowShortcut: String { settingsStore.value.moveWindowHotkey }
    var toggleShortcut: String { settingsStore.value.toggleLineHotkey }
    var nightShiftShortcut: String { settingsStore.value.nightShiftHotkey }

    var choiceGroups: [ChoiceGroup] {
        let settings = settingsStore.value
        return [
            group(String(localized: "Hanging Style"), HangStyle.allCases, selected: settings.hangStyle, keyPath: \.hangStyle,
                  title: \.title, symbol: \.symbol),
            group(String(localized: "Sway"), SwayStyle.allCases, selected: settings.sway, keyPath: \.sway, title: \.title),
            group(String(localized: "Switch Effect"), SwitchEffect.allCases, selected: settings.switchEffect, keyPath: \.switchEffect,
                  title: \.title),
            group(String(localized: "Particles"), ParticleStyle.allCases, selected: settings.particles, keyPath: \.particles,
                  title: \.title),
            group(String(localized: "Name Banner"), NameBannerStyle.allCases, selected: settings.banner, keyPath: \.banner,
                  title: \.title),
            group(String(localized: "Desktop Line"), LineVisibility.allCases, selected: settings.visibility, keyPath: \.visibility,
                  title: \.title)
        ]
    }

    var languageGroup: ChoiceGroup {
        let saved = AppLanguage.saved()
        return ChoiceGroup(
            title: String(localized: "Language"),
            choices: AppLanguage.allCases.map { language in
                Choice(title: language.title, symbol: nil, isSelected: language == saved) { [weak self] in
                    self?.setLanguage(language)
                }
            }
        )
    }

    private func group<Option: Equatable>(
        _ title: String,
        _ options: [Option],
        selected: Option,
        keyPath: WritableKeyPath<AppSettings, Option>,
        title optionTitle: KeyPath<Option, String>,
        symbol: KeyPath<Option, String>? = nil
    ) -> ChoiceGroup {
        ChoiceGroup(title: title, choices: options.map { option in
            Choice(
                title: option[keyPath: optionTitle],
                symbol: symbol.map { option[keyPath: $0] },
                isSelected: option == selected
            ) { [weak self] in
                self?.settingsStore.value[keyPath: keyPath] = option
            }
        })
    }

    // MARK: Intents

    func go(to space: DesktopSpace) {
        desktops.go(to: space)
    }

    func renameCurrent() {
        desktops.renameCurrent()
    }

    func toggleLine() {
        line.toggle()
    }

    func addDesktop() {
        Task { await desktops.addDesktopHere() }
    }

    func delete(_ space: DesktopSpace) {
        Task { await desktops.delete(space) }
    }

    func turnAllScreensOn() {
        displays.turnEverythingOn()
    }

    func allowSwitching() {
        desktops.requestSwitchingPermission()
    }

    func setLanguage(_ language: AppLanguage) {
        guard language != AppLanguage.saved() else { return }
        AppLanguage.save(language)
        if dialogs.confirmLanguageRestart() { AppRelauncher.relaunch() }
    }
}
