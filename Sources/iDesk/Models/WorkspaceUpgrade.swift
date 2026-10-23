import Foundation

struct DesktopOrganization: Codable, Equatable {
    var group = ""
    var tags = ""
    var favorite = false
}

struct ContextPresetRule: Codable, Equatable, Identifiable {
    enum Event: String, Codable, CaseIterable { case appLaunched, displayConnected, displayDisconnected, topologyChanged }
    var id = UUID().uuidString
    var event: Event = .appLaunched
    /// Bundle identifier for application events; sorted display UUIDs for topology events.
    var match = ""
    var presetID: String
    var priority = 0
    var cooldown: TimeInterval = 60
    var isEnabled = false
}

struct WorkspacePreferences: Codable, Equatable {
    var organization: [String: DesktopOrganization] = [:]
    var pinnedCommands: Set<String> = []
    var recentCommands: [String] = []
    var contextRules: [ContextPresetRule] = []
    var automationPaused = true
    var showsWindowBadges = true
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organization = (try? c.decode([String: DesktopOrganization].self, forKey: .organization)) ?? [:]
        pinnedCommands = (try? c.decode(Set<String>.self, forKey: .pinnedCommands)) ?? []
        recentCommands = (try? c.decode([String].self, forKey: .recentCommands)) ?? []
        contextRules = (try? c.decode([ContextPresetRule].self, forKey: .contextRules)) ?? []
        automationPaused = (try? c.decode(Bool.self, forKey: .automationPaused)) ?? true
        showsWindowBadges = (try? c.decode(Bool.self, forKey: .showsWindowBadges)) ?? true
    }
}

enum WindowArrangement: String, CaseIterable, Identifiable {
    case left, right, firstThird, lastThird, firstTwoThirds, lastTwoThirds, center, maximize, grid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: String(localized: "Left Half")
        case .right: String(localized: "Right Half")
        case .firstThird: String(localized: "First Third")
        case .lastThird: String(localized: "Last Third")
        case .firstTwoThirds: String(localized: "First Two Thirds")
        case .lastTwoThirds: String(localized: "Last Two Thirds")
        case .center: String(localized: "Center")
        case .maximize: String(localized: "Maximize")
        case .grid: String(localized: "2 × 2 Grid")
        }
    }
    func frame(in bounds: CGRect, original: CGRect, index: Int) -> CGRect {
        switch self {
        case .left: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .right: return CGRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .firstThird: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 3, height: bounds.height)
        case .lastThird: return CGRect(x: bounds.minX + bounds.width * 2 / 3, y: bounds.minY, width: bounds.width / 3, height: bounds.height)
        case .firstTwoThirds: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width * 2 / 3, height: bounds.height)
        case .lastTwoThirds: return CGRect(x: bounds.minX + bounds.width / 3, y: bounds.minY, width: bounds.width * 2 / 3, height: bounds.height)
        case .maximize: return bounds
        case .center:
            let size = CGSize(width: min(original.width, bounds.width), height: min(original.height, bounds.height))
            return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        case .grid:
            return CGRect(x: bounds.minX + CGFloat(index % 2) * bounds.width / 2,
                          y: bounds.minY + CGFloat((index / 2) % 2) * bounds.height / 2,
                          width: bounds.width / 2, height: bounds.height / 2)
        }
    }
}

struct AdaptiveWindowFrame {
    static func normalize(_ frame: CGRect, in bounds: CGRect) -> CGRect? {
        guard valid(frame), valid(bounds) else { return nil }
        return CGRect(x: (frame.minX - bounds.minX) / bounds.width, y: (frame.minY - bounds.minY) / bounds.height,
                      width: frame.width / bounds.width, height: frame.height / bounds.height)
    }
    static func resolve(_ normalized: CGRect?, absolute: CGRect?, in bounds: CGRect?) -> CGRect? {
        if let normalized, valid(normalized), let bounds, valid(bounds) {
            let frame = CGRect(x: bounds.minX + normalized.minX * bounds.width, y: bounds.minY + normalized.minY * bounds.height,
                               width: normalized.width * bounds.width, height: normalized.height * bounds.height)
            return valid(frame) ? frame : nil
        }
        return absolute.flatMap { valid($0) ? $0 : nil }
    }
    static func valid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }
}
