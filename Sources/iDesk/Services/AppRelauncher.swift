import AppKit

enum AppRelauncher {
    /// Opens a fresh copy of iDesk and quits this one, for example after
    /// the interface language changed.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}
