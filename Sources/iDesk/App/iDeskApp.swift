import AppKit

/// iDesk lives in the menu bar; it has no Dock icon and no main window.
@main
enum iDeskMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Creates the environment and the windows that show its view models.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?
    private var lineWindow: DesktopLineWindowController?
    private var bannerWindow: NameBannerWindowController?
    private var settingsWindow: SettingsWindowController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment(dialogs: AlertDialogs())
        self.environment = environment

        let settingsWindow = SettingsWindowController(makeViewModel: environment.makeSettingsViewModel)
        self.settingsWindow = settingsWindow
        menuBar = MenuBarController(viewModel: environment.menuBar, openSettings: settingsWindow.show)
        bannerWindow = NameBannerWindowController(viewModel: environment.banner)

        environment.start()
        let lineWindow = DesktopLineWindowController(viewModel: environment.line)
        lineWindow.start()
        self.lineWindow = lineWindow
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
