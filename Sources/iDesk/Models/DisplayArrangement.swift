import CoreGraphics
import Foundation

/// One screen connected to the Mac, on or off.
struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var isBuiltin: Bool
    var isEnabled: Bool
}

/// Which screens are on. Each keeps whatever macOS shows on it.
struct DisplayLayout: Equatable {
    var enabled: Set<CGDirectDisplayID>
}

/// The ways to use several screens, for example while streaming.
enum DisplayArrangement: Hashable {
    /// Every screen on.
    case allOn
    /// Only the main screen is on.
    case mainOnly
    /// Only one external screen is on.
    case externalOnly(CGDirectDisplayID)
    /// Anything else, for example two of three screens.
    case custom

    var title: String {
        switch self {
        case .allOn: String(localized: "All Screens On")
        case .mainOnly: String(localized: "Main Screen Only")
        case .externalOnly: String(localized: "External Screen Only")
        case .custom: String(localized: "Custom")
        }
    }

    var symbol: String {
        switch self {
        case .allOn: "display.2"
        case .mainOnly: "laptopcomputer"
        case .externalOnly: "display"
        case .custom: "slider.horizontal.3"
        }
    }

    /// The main screen: the built-in one on a laptop, otherwise the one
    /// with the menu bar.
    static func primary(of displays: [DisplayInfo], menuBarDisplay: CGDirectDisplayID) -> CGDirectDisplayID? {
        displays.first(where: \.isBuiltin)?.id ?? displays.first { $0.id == menuBarDisplay }?.id ?? displays.first?.id
    }

    /// The layout that makes this arrangement real.
    func layout(for displays: [DisplayInfo], primary: CGDirectDisplayID) -> DisplayLayout? {
        let all = Set(displays.map(\.id))
        switch self {
        case .allOn: return DisplayLayout(enabled: all)
        case .mainOnly: return DisplayLayout(enabled: [primary])
        case let .externalOnly(id):
            guard all.contains(id), id != primary else { return nil }
            return DisplayLayout(enabled: [id])
        case .custom: return nil
        }
    }

    /// Which arrangement the displays are in now.
    static func current(of displays: [DisplayInfo], primary: CGDirectDisplayID) -> DisplayArrangement {
        let enabled = displays.filter(\.isEnabled)
        if enabled.count == displays.count { return .allOn }
        if enabled.count == 1, let only = enabled.first {
            return only.id == primary ? .mainOnly : .externalOnly(only.id)
        }
        return .custom
    }
}
