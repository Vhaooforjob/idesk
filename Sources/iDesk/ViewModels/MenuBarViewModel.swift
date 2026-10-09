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

    private let desktops: DesktopsViewModel
    private let line: DesktopLineViewModel
    private let displays: DisplaysViewModel
    private let settingsStore: SettingsStore
    private let dialogs: DialogPresenting
    private var cancellables: Set<AnyCancellable> = []

    init(desktops: DesktopsViewModel, line: DesktopLineViewModel, displays: DisplaysViewModel,
         settingsStore: SettingsStore, dialogs: DialogPresenting) {
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
        let fresh = Self.title(for: desktops.currentSpace(on: NSScreen.main ?? SpaceService.screenUnderPointer),
                               settings: settingsStore.value)
        if fresh != title { title = fresh }
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
        desktops.reload()
        displays.refresh()
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

    var needsSwitchingPermission: Bool { !PermissionService.canSwitchDesktops }
    var restoreDisplaysShortcut: String { settingsStore.value.restoreDisplaysHotkey }
    var renameShortcut: String { settingsStore.value.renameHotkey }
    var toggleShortcut: String { settingsStore.value.toggleLineHotkey }

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
