import Foundation

enum DesktopLineLayout: String, Codable, CaseIterable, Identifiable {
    case fit, scroll, grid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: String(localized: "Fit All Desktops")
        case .scroll: String(localized: "Scrollable Line")
        case .grid: String(localized: "Desktop Grid")
        }
    }
}

struct WindowRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var bundleID: String
    var appName: String
    var titleContains = ""
    var desktopID: String
    var isEnabled = true
}

struct SessionLaunchItem: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var address: String
    var name: String

    var url: URL? {
        guard let url = URL(string: address),
              ["file", "https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.isFileURL || url.host != nil else { return nil }
        return url
    }
}

struct SavedWindowPlacement: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var bundleID: String
    var title: String
    var desktopID: String
    /// Accessibility coordinates, in points with the origin at the top left.
    var frame: CGRect?
    var normalizedFrame: CGRect?
    var displayIdentity: String?
}

struct WorkspaceSession: Codable, Equatable {
    var launchItems: [SessionLaunchItem] = []
    var windows: [SavedWindowPlacement] = []
}

struct WorkspaceFeatureError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
