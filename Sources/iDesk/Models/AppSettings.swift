import Foundation

/// How the desktops hang under the menu bar.
enum HangStyle: String, Codable, CaseIterable, Identifiable {
    /// A sagging rope with aluminium clips, like iSnap's Capture Line.
    case clothesline
    /// Each desktop on its own thread from a pin, at different lengths.
    case strings
    /// Picture frames, each on a nail with a wire.
    case frames
    /// A rope of coloured pennants with wooden pegs.
    case bunting
    /// A wire of twinkling bulbs with small hooks.
    case fairyLights
    /// A straight brushed rail with magnets.
    case rail

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clothesline: String(localized: "Clothesline")
        case .strings: String(localized: "Strings")
        case .frames: String(localized: "Picture Frames")
        case .bunting: String(localized: "Bunting")
        case .fairyLights: String(localized: "Fairy Lights")
        case .rail: String(localized: "Magnetic Rail")
        }
    }

    var symbol: String {
        switch self {
        case .clothesline: "tshirt"
        case .strings: "pendant.light"
        case .frames: "photo.artframe"
        case .bunting: "flag.2.crossed"
        case .fairyLights: "lightbulb.2"
        case .rail: "minus.rectangle"
        }
    }
}

/// The idle motion of the cards.
enum SwayStyle: String, Codable, CaseIterable, Identifiable {
    case still, gentle, windy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .still: String(localized: "Still")
        case .gentle: String(localized: "Gentle Breeze")
        case .windy: String(localized: "Windy")
        }
    }
}

/// What the card of the desktop you arrive on does.
enum SwitchEffect: String, Codable, CaseIterable, Identifiable {
    case swing, bounce, spin, glow, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swing: String(localized: "Swing")
        case .bounce: String(localized: "Bounce")
        case .spin: String(localized: "Spin")
        case .glow: String(localized: "Glow")
        case .none: String(localized: "None")
        }
    }
}

/// Something drifting around the line while it is down.
enum ParticleStyle: String, Codable, CaseIterable, Identifiable {
    case none, snow, sparkles, petals, leaves

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .snow: String(localized: "Snow")
        case .sparkles: String(localized: "Sparkles")
        case .petals: String(localized: "Cherry Petals")
        case .leaves: String(localized: "Autumn Leaves")
        }
    }
}

/// The desktop's name shown for a moment after switching.
enum NameBannerStyle: String, Codable, CaseIterable, Identifiable {
    case hangingSign, pill, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hangingSign: String(localized: "Hanging Sign")
        case .pill: String(localized: "Glass Pill")
        case .none: String(localized: "Off")
        }
    }
}

enum LineVisibility: String, Codable, CaseIterable, Identifiable {
    case onHover, always, hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onHover: String(localized: "Show on Hover")
        case .always: String(localized: "Always Show")
        case .hidden: String(localized: "Only with Shortcut")
        }
    }
}

enum MenuBarTitle: String, Codable, CaseIterable, Identifiable {
    case name, numberAndName, icon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: String(localized: "Desktop Name")
        case .numberAndName: String(localized: "Number and Name")
        case .icon: String(localized: "Icon Only")
        }
    }
}

/// Everything iDesk remembers. Every field falls back to its default so
/// settings written by an older version still load.
struct AppSettings: Codable, Equatable {
    var hangStyle: HangStyle = .clothesline
    var sway: SwayStyle = .gentle
    var switchEffect: SwitchEffect = .swing
    var particles: ParticleStyle = .none
    var banner: NameBannerStyle = .hangingSign
    var visibility: LineVisibility = .onHover
    var menuBarTitle: MenuBarTitle = .numberAndName
    var showsFullScreenSpaces = false
    var showsPreviews = true
    var playsSounds = false
    var toggleLineHotkey = "⌃⌥D"
    var renameHotkey = "⌃⌥R"
    /// A way back when a screen setup leaves you without a usable screen.
    var restoreDisplaysHotkey = "⌃⌥⌘D"
    /// Desktop names by Space UUID. A missing or empty name means the
    /// default "Desktop N".
    var names: [String: String] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        hangStyle = (try? c.decode(HangStyle.self, forKey: .hangStyle)) ?? d.hangStyle
        sway = (try? c.decode(SwayStyle.self, forKey: .sway)) ?? d.sway
        switchEffect = (try? c.decode(SwitchEffect.self, forKey: .switchEffect)) ?? d.switchEffect
        particles = (try? c.decode(ParticleStyle.self, forKey: .particles)) ?? d.particles
        banner = (try? c.decode(NameBannerStyle.self, forKey: .banner)) ?? d.banner
        visibility = (try? c.decode(LineVisibility.self, forKey: .visibility)) ?? d.visibility
        menuBarTitle = (try? c.decode(MenuBarTitle.self, forKey: .menuBarTitle)) ?? d.menuBarTitle
        showsFullScreenSpaces = (try? c.decode(Bool.self, forKey: .showsFullScreenSpaces)) ?? d.showsFullScreenSpaces
        showsPreviews = (try? c.decode(Bool.self, forKey: .showsPreviews)) ?? d.showsPreviews
        playsSounds = (try? c.decode(Bool.self, forKey: .playsSounds)) ?? d.playsSounds
        toggleLineHotkey = (try? c.decode(String.self, forKey: .toggleLineHotkey)) ?? d.toggleLineHotkey
        renameHotkey = (try? c.decode(String.self, forKey: .renameHotkey)) ?? d.renameHotkey
        restoreDisplaysHotkey = (try? c.decode(String.self, forKey: .restoreDisplaysHotkey)) ?? d.restoreDisplaysHotkey
        names = (try? c.decode([String: String].self, forKey: .names)) ?? d.names
    }

    func name(for space: DesktopSpace) -> String {
        let custom = names[space.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? space.defaultName : custom
    }

    mutating func setName(_ name: String, for space: DesktopSpace) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[space.id] = trimmed.isEmpty || trimmed == space.defaultName ? nil : trimmed
    }
}
