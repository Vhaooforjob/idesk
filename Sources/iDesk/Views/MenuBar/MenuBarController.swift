import AppKit
import Combine

/// The menu bar item: an icon with the current desktop's name, and a menu
/// rebuilt from its view model each time it opens.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let viewModel: MenuBarViewModel
    private let openSettings: () -> Void
    private let openWindowPicker: () -> Void
    private let openDesktopSearch: () -> Void
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: MenuBarViewModel, openSettings: @escaping () -> Void, openWindowPicker: @escaping () -> Void, openDesktopSearch: @escaping () -> Void) {
        self.openDesktopSearch = openDesktopSearch
        self.viewModel = viewModel
        self.openSettings = openSettings
        self.openWindowPicker = openWindowPicker
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        viewModel.$appearance.sink { [weak self] appearance in
            guard let button = self?.statusItem.button else { return }
            Self.configureIcon(of: button, symbol: appearance.symbol)
        }.store(in: &cancellables)
        viewModel.$title
            .combineLatest(viewModel.$currentName)
            .sink { [weak self] title, name in self?.show(title, name: name) }
            .store(in: &cancellables)
    }

    /// The icon is a template and the button is never tinted, so the status
    /// bar picks a legible foreground for its background and highlight
    /// state, for the icon and for the desktop name beside it. A desktop's
    /// own color is shown inside iDesk's views, not here.
    static func configureIcon(of button: NSButton, symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "iDesk")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = nil
    }

    /// Shows the title cut to fit, with the full desktop name as tooltip
    /// and as the VoiceOver label.
    static func configureTitle(of button: NSButton, title: String, name: String) {
        let shown = MenuBarViewModel.shortened(title)
        button.title = shown.isEmpty ? "" : " \(shown)"
        button.imagePosition = shown.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = name.isEmpty ? nil : name
        button.setAccessibilityLabel(name.isEmpty ? "iDesk" : "iDesk, \(name)")
    }

    private func show(_ title: String, name: String) {
        guard let button = statusItem.button else { return }
        Self.configureTitle(of: button, title: title, name: name)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        viewModel.refresh()
        menu.removeAllItems()

        let sections = viewModel.sections
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if let title = section.title {
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
            }
            for entry in section.entries {
                let space = entry.space
                let item = LineMenuItem(entry.title) { [weak self] in self?.viewModel.go(to: space) }
                item.showShortcut(viewModel.desktopShortcut(space))
                item.state = space.isCurrent ? .on : .off
                let appearance = viewModel.appearance(for: space)
                item.image = NSImage(systemSymbolName: appearance.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(appearance.color.color)]))
                menu.addItem(item)
            }
        }
        if sections.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No desktops found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let search = LineMenuItem(String(localized: "Command Palette")) { [weak self] in self?.openDesktopSearch() }
        search.showShortcut(viewModel.searchShortcut)
        menu.addItem(search)
        let previous = LineMenuItem(String(localized: "Previous Desktop")) { [weak self] in self?.viewModel.previousDesktop() }
        previous.showShortcut(viewModel.previousShortcut)
        menu.addItem(previous)
        let picker = LineMenuItem(String(localized: "Find and Move Windows…")) { [weak self] in self?.openWindowPicker() }
        picker.showShortcut(viewModel.moveWindowShortcut)
        menu.addItem(picker)
        let undo = LineMenuItem(String(localized: "Undo Window Move")) { [weak self] in self?.viewModel.undoMove() }
        undo.isEnabled = viewModel.canUndoMove
        undo.showShortcut(viewModel.undoShortcut)
        menu.autoenablesItems = false
        menu.addItem(undo)
        let toggle = LineMenuItem(String(localized: "Show or Hide the Line")) { [weak self] in self?.viewModel.toggleLine() }
        toggle.showShortcut(viewModel.toggleShortcut)
        menu.addItem(toggle)

        menu.addItem(.separator())
        menu.addItem(desktopActionsMenu())
        menu.addItem(appearanceMenu())
        let presets = viewModel.presets.suggestions + viewModel.presets.presets
        menu.addItem(submenu(for: MenuBarViewModel.ChoiceGroup(title: String(localized: "Presets"), choices: presets.map { preset in
            MenuBarViewModel.Choice(title: preset.name, symbol: "slider.horizontal.3", isSelected: false) { [weak self] in
                self?.viewModel.applyPreset(preset)
            }
        })))
        if let screens = viewModel.screenGroups { menu.addItem(screensMenu(screens)) }
        if viewModel.needsSwitchingPermission {
            menu.addItem(LineMenuItem(String(localized: "Allow Switching Desktops…")) { [weak self] in self?.viewModel.allowSwitching() })
        }

        menu.addItem(.separator())
        menu.addItem(LineMenuItem(String(localized: "Settings…"), key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(LineMenuItem(String(localized: "Quit iDesk"), key: "q") { NSApp.terminate(nil) })
    }

    private func desktopActionsMenu() -> NSMenuItem {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let rename = LineMenuItem(String(localized: "Rename Current Desktop…")) { [weak self] in self?.viewModel.renameCurrent() }
        rename.showShortcut(viewModel.renameShortcut)
        menu.addItem(rename)
        let moveGroup = viewModel.moveWindowGroup
        if !moveGroup.choices.isEmpty { menu.addItem(submenu(for: moveGroup)) }
        menu.addItem(.separator())
        menu.addItem(LineMenuItem(String(localized: "Add Desktop")) { [weak self] in self?.viewModel.addDesktop() })
        let deletable = viewModel.deletableDesktops
        let deleteMenu = NSMenu()
        for entry in deletable {
            let space = entry.space
            deleteMenu.addItem(LineMenuItem(entry.title + "…") { [weak self] in self?.viewModel.delete(space) })
        }
        let deleteItem = NSMenuItem(title: String(localized: "Delete Desktop"), action: nil, keyEquivalent: "")
        deleteItem.submenu = deleteMenu
        deleteItem.isEnabled = !deletable.isEmpty
        menu.addItem(deleteItem)
        return groupItem(String(localized: "Desktop Actions"), menu: menu)
    }

    private func appearanceMenu() -> NSMenuItem {
        let menu = NSMenu()
        for group in viewModel.choiceGroups { menu.addItem(submenu(for: group)) }
        menu.addItem(.separator())
        menu.addItem(submenu(for: viewModel.languageGroup))
        return groupItem(String(localized: "Appearance"), menu: menu)
    }

    private func groupItem(_ title: String, menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    /// What the screens show, each screen on or off, and the way back.
    private func screensMenu(_ groups: (arrangements: MenuBarViewModel.ChoiceGroup, screens: MenuBarViewModel.ChoiceGroup,
                                        canTurnAllOn: Bool)) -> NSMenuItem {
        let item = submenu(for: groups.arrangements)
        guard let menu = item.submenu else { return item }
        if !groups.screens.choices.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: groups.screens.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for choice in groups.screens.choices {
                let screen = LineMenuItem(choice.title, handler: choice.select)
                screen.state = choice.isSelected ? .on : .off
                screen.isEnabled = choice.isEnabled
                menu.autoenablesItems = false
                if let symbol = choice.symbol { screen.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
                menu.addItem(screen)
            }
        }
        if groups.canTurnAllOn {
            menu.addItem(.separator())
            let restore = LineMenuItem(String(localized: "Turn Every Screen Back On")) { [weak self] in self?.viewModel.turnAllScreensOn() }
            restore.showShortcut(viewModel.restoreDisplaysShortcut)
            menu.addItem(restore)
        }
        return item
    }

    /// A submenu of mutually exclusive options with the current one ticked.
    private func submenu(for group: MenuBarViewModel.ChoiceGroup) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for choice in group.choices {
            let item = LineMenuItem(choice.title, handler: choice.select)
            item.state = choice.isSelected ? .on : .off
            item.isEnabled = choice.isEnabled
            if let symbol = choice.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }
}

extension NSMenuItem {
    /// Shows a shortcut written like "⌃⌥D" next to the item. It is only a
    /// hint: the shortcut itself is registered system-wide.
    func showShortcut(_ shortcut: String) {
        var modifiers: NSEvent.ModifierFlags = []
        if shortcut.contains("⌘") { modifiers.insert(.command) }
        if shortcut.contains("⌃") { modifiers.insert(.control) }
        if shortcut.contains("⌥") { modifiers.insert(.option) }
        if shortcut.contains("⇧") { modifiers.insert(.shift) }
        let key = shortcut.filter { !"⌘⌃⌥⇧".contains($0) }.lowercased()
        // Arrows, Tab and Return are special keys in a menu; the hint is
        // only for plain characters.
        guard !modifiers.isEmpty, key.count == 1, key.unicodeScalars.allSatisfy(\.isASCII) else { return }
        keyEquivalent = key
        keyEquivalentModifierMask = modifiers
    }
}
