import Foundation

/// The questions view models need to ask the user. The app answers them
/// with alerts; tests answer them directly.
@MainActor
protocol DialogPresenting: AnyObject {
    /// The new name for a desktop, or nil when cancelled. An empty name
    /// means the default one.
    func askForName(of space: DesktopSpace, current: String) -> String?
    /// True when the user wants to grant Accessibility access now.
    func confirmAccessibility() -> Bool
    /// True when the user wants to open the Mission Control shortcuts.
    func confirmShortcutSettings() -> Bool
    /// True when the user wants to restart now for a new language.
    func confirmLanguageRestart() -> Bool
    /// True when the user really wants to delete the desktop. Its windows
    /// move to another desktop.
    func confirmDelete(desktopNamed name: String) -> Bool
    /// True when the user keeps a new screen setup. Unanswered after
    /// `seconds` it counts as no, so a setup that hides the dialog undoes
    /// itself.
    func confirmKeepDisplays(seconds: Int) -> Bool
    func showError(_ title: String, _ error: Error)
    /// Explains that iDesk could not do it and offers Mission Control,
    /// where the user can do it by hand. True to open it.
    func offerMissionControl(_ title: String, _ error: Error, howTo: String) -> Bool
}
