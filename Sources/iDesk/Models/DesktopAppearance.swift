import SwiftUI

enum DesktopColor: String, Codable, CaseIterable, Identifiable {
    case accent, blue, green, orange, purple, pink, red
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accent: String(localized: "Default")
        case .blue: String(localized: "Blue")
        case .green: String(localized: "Green")
        case .orange: String(localized: "Orange")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .red: String(localized: "Red")
        }
    }
    var color: Color {
        switch self {
        case .accent: .accentColor
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        }
    }
}

struct DesktopAppearance: Codable, Equatable {
    var color: DesktopColor = .accent
    var symbol = "rectangle.on.rectangle"
    static let symbols = ["rectangle.on.rectangle", "chevron.left.forwardslash.chevron.right",
                          "video", "paintbrush", "music.note", "house", "briefcase", "book", "gamecontroller", "star"]
}

/// Presets deliberately exclude names, shortcuts and preview storage policy.
struct WorkspacePreset: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var hangStyle: HangStyle
    var sway: SwayStyle
    var switchEffect: SwitchEffect
    var particles: ParticleStyle
    var banner: NameBannerStyle
    var visibility: LineVisibility
    var showsPreviews: Bool
    var playsSounds: Bool
    var screens: PresetScreens = .unchanged
    var externalDisplayIdentity: String?
    var session: WorkspaceSession?
    var lineLayout: DesktopLineLayout?

    init(name: String, settings: AppSettings, screens: PresetScreens = .unchanged) {
        self.name = name
        hangStyle = settings.hangStyle
        sway = settings.sway
        switchEffect = settings.switchEffect
        particles = settings.particles
        banner = settings.banner
        visibility = settings.visibility
        showsPreviews = settings.showsPreviews
        playsSounds = settings.playsSounds
        self.screens = screens
        lineLayout = settings.lineLayout
    }

    func apply(to settings: inout AppSettings) {
        if let lineLayout { settings.lineLayout = lineLayout }
        settings.hangStyle = hangStyle
        settings.sway = sway
        settings.switchEffect = switchEffect
        settings.particles = particles
        settings.banner = banner
        settings.visibility = visibility
        settings.showsPreviews = showsPreviews
        settings.playsSounds = playsSounds
    }

    static var suggestions: [WorkspacePreset] {
        var coding = AppSettings()
        coding.sway = .still
        coding.particles = .none
        coding.banner = .pill
        var meeting = coding
        meeting.visibility = .hidden
        meeting.banner = .none
        meeting.showsPreviews = false
        var presenting = meeting
        presenting.switchEffect = .none
        return [
            WorkspacePreset(name: String(localized: "Coding"), settings: coding),
            WorkspacePreset(name: String(localized: "Meeting"), settings: meeting),
            WorkspacePreset(name: String(localized: "Presenting"), settings: presenting, screens: .allOn)
        ]
    }
}

enum PresetScreens: String, Codable, CaseIterable, Identifiable {
    case unchanged, allOn, mainOnly, externalOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unchanged: String(localized: "Keep Current Screens")
        case .allOn: String(localized: "All Screens On")
        case .mainOnly: String(localized: "Main Screen Only")
        case .externalOnly: String(localized: "External Screen Only")
        }
    }
}
