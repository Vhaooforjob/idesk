import AppKit
import Combine

/// The menu bar item: an icon with the current desktop's name, and a menu
/// rebuilt from its view model each time it opens.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let viewModel: MenuBarViewModel
    private let openSettings: () -> Void
    private let statusItem: NSStatusItem
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: MenuBarViewModel, openSettings: @escaping () -> Void) {
        self.viewModel = viewModel
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "iDesk")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        viewModel.$title
            .sink { [weak self] title in self?.show(title) }
            .store(in: &cancellables)
    }

    private func show(_ title: String) {
        guard let button = statusItem.button else { return }
        button.title = title.isEmpty ? "" : " \(title)"
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
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
                item.state = space.isCurrent ? .on : .off
                menu.addItem(item)
            }
        }
        if sections.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No desktops found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let rename = LineMenuItem(String(localized: "Rename Current Desktop…")) { [weak self] in self?.viewModel.renameCurrent() }
        rename.showShortcut(viewModel.renameShortcut)
        menu.addItem(rename)
        let toggle = LineMenuItem(String(localized: "Show or Hide the Line")) { [weak self] in self?.viewModel.toggleLine() }
        toggle.showShortcut(viewModel.toggleShortcut)
        menu.addItem(toggle)
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
        if viewModel.needsSwitchingPermission {
            menu.addItem(LineMenuItem(String(localized: "Allow Switching Desktops…")) { [weak self] in self?.viewModel.allowSwitching() })
        }

        if let screens = viewModel.screenGroups {
            menu.addItem(.separator())
            menu.addItem(screensMenu(screens))
        }

        menu.addItem(.separator())
        for group in viewModel.choiceGroups { menu.addItem(submenu(for: group)) }

        menu.addItem(.separator())
        menu.addItem(LineMenuItem(String(localized: "Settings…"), key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(submenu(for: viewModel.languageGroup))
        menu.addItem(.separator())
        menu.addItem(LineMenuItem(String(localized: "Quit iDesk"), key: "q") { NSApp.terminate(nil) })
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
        for choice in group.choices {
            let item = LineMenuItem(choice.title, handler: choice.select)
            item.state = choice.isSelected ? .on : .off
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
        guard !modifiers.isEmpty, key.count == 1 else { return }
        keyEquivalent = key
        keyEquivalentModifierMask = modifiers
    }
}
