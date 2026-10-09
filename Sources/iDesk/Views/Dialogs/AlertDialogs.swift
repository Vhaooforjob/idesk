import AppKit

/// Answers view model questions with standard alerts. iDesk has no Dock
/// icon, so it comes to the front first.
@MainActor
final class AlertDialogs: DialogPresenting {
    func askForName(of space: DesktopSpace, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Desktop")
        alert.informativeText = String(localized: "Give \(space.defaultName) a name. Leave it empty to use the default name.")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = space.defaultName
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        return run(alert) ? field.stringValue : nil
    }

    func confirmAccessibility() -> Bool {
        confirm(
            String(localized: "Allow iDesk to switch desktops"),
            String(localized: "macOS only lets apps switch desktops by pressing the Mission Control shortcuts. Turn on iDesk under Privacy & Security → Accessibility, then click the desktop again."),
            action: String(localized: "Open System Settings")
        )
    }

    func confirmShortcutSettings() -> Bool {
        confirm(
            String(localized: "Turn on a Mission Control shortcut"),
            String(localized: "iDesk switches desktops with “Move left a space” and “Move right a space”, or “Switch to Desktop N”. Turn them on in System Settings → Keyboard → Keyboard Shortcuts → Mission Control."),
            action: String(localized: "Open Keyboard Settings")
        )
    }

    func confirmLanguageRestart() -> Bool {
        confirm(
            String(localized: "Restart iDesk to change the language?"),
            String(localized: "The new language is used the next time iDesk opens."),
            action: String(localized: "Restart Now")
        )
    }

    func confirmDelete(desktopNamed name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete “\(name)”?")
        alert.informativeText = String(localized: "Its windows move to another desktop. Mission Control opens for a moment to do this.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return run(alert)
    }

    func confirmKeepDisplays(seconds: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Keep this screen setup?")
        alert.addButton(withTitle: String(localized: "Keep"))
        alert.addButton(withTitle: String(localized: "Undo"))
        var remaining = seconds
        let update = {
            alert.informativeText = String(localized: "The screens go back to how they were in \(remaining) seconds.")
        }
        update()
        // Counts down inside the modal session; at zero the alert answers no.
        let timer = Timer(timeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                remaining -= 1
                update()
                if remaining <= 0 {
                    timer.invalidate()
                    NSApp.abortModal()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        return run(alert)
    }

    func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        _ = run(alert)
    }

    func offerMissionControl(_ title: String, _ error: Error, howTo: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription + "\n\n" + howTo
        alert.addButton(withTitle: String(localized: "Open Mission Control"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return run(alert)
    }

    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: String(localized: "Later"))
        return run(alert)
    }

    private func run(_ alert: NSAlert) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
