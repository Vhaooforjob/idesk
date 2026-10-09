import AppKit

/// One desktop hanging on the line.
struct HangingDesktop: Identifiable, Equatable {
    let space: DesktopSpace
    var name: String
    var thumbnail: NSImage?
    /// Width over height of the display, for pictures not taken yet.
    var aspect: CGFloat = 16 / 10

    var id: String { space.id }

    /// Every card hangs a little crooked, and the same way at every launch.
    var tilt: Double { Self.tilt(for: space.id) }

    static func tilt(for id: String) -> Double {
        Double(hash(id) % 1000) / 1000 * 5 - 2.5
    }

    /// A colour of its own for a desktop that has no picture yet.
    static func hue(for id: String) -> Double {
        Double((hash(id) >> 10) % 360) / 360
    }

    /// djb2, then mixed so that similar ids land far apart.
    private static func hash(_ id: String) -> UInt64 {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return hash &* 0x9E37_79B9_7F4A_7C15
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.space == rhs.space && lhs.name == rhs.name && lhs.thumbnail === rhs.thumbnail && lhs.aspect == rhs.aspect
    }
}

/// How the line looks and moves, taken from the settings.
struct LineLook: Equatable {
    var style: HangStyle = .clothesline
    var sway: SwayStyle = .gentle
    var effect: SwitchEffect = .swing
    var particles: ParticleStyle = .none

    init() {}

    init(_ settings: AppSettings) {
        style = settings.hangStyle
        sway = settings.sway
        effect = settings.switchEffect
        particles = settings.particles
    }
}
