import Foundation

/// What iDesk remembers about the picture of one external screen. Stored
/// in the settings by the screen's UUID, so it follows the screen between
/// ports. A screen with hardware brightness keeps that level in the screen
/// itself: only the software part is saved here.
struct ScreenTuning: Codable, Equatable {
    /// 0.1...1. Used only when the screen cannot be dimmed in hardware.
    var softwareBrightness = 1.0
    /// 0 leaves the colors alone, 1 is the warmest.
    var warmth = 0.0

    init(softwareBrightness: Double = 1, warmth: Double = 0) {
        self.softwareBrightness = Self.clamp(softwareBrightness, ScreenColor.minimumBrightness, 1)
        self.warmth = Self.clamp(warmth, 0, 1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            softwareBrightness: (try? c.decode(Double.self, forKey: .softwareBrightness)) ?? 1,
            warmth: (try? c.decode(Double.self, forKey: .warmth)) ?? 0
        )
    }

    /// Nothing to apply: the screen shows what macOS sends.
    var isNeutral: Bool { softwareBrightness >= 0.999 && warmth <= 0.001 }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        value.isFinite ? min(max(value, low), high) : low
    }
}

/// How a screen's brightness is changed.
enum BrightnessControl: Equatable {
    /// The screen's own backlight, through DDC/CI. `maximum` is what the
    /// screen reports as its top level, usually 100.
    case hardware(maximum: Int)
    /// Darkening what macOS sends, for screens that do not answer DDC/CI.
    case software
}

/// The math behind dimming and warming a screen with a gamma table.
enum ScreenColor {
    /// The software level never goes to black, so a slider cannot leave a
    /// screen unreadable.
    static let minimumBrightness = 0.1
    static let neutralKelvin = 6500.0
    static let warmestKelvin = 2700.0

    struct Gain: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        static let identity = Gain(red: 1, green: 1, blue: 1)
    }

    /// The multiplier for each color channel. Warmth lowers blue the most
    /// and green a little, like a lower color temperature.
    static func gain(brightness: Double, warmth: Double) -> Gain {
        let level = min(max(brightness, minimumBrightness), 1)
        let warm = min(max(warmth, 0), 1)
        let target = rgb(kelvin: neutralKelvin - warm * (neutralKelvin - warmestKelvin))
        let neutral = rgb(kelvin: neutralKelvin)
        return Gain(
            red: level * min(target.red / neutral.red, 1),
            green: level * min(target.green / neutral.green, 1),
            blue: level * min(target.blue / neutral.blue, 1)
        )
    }

    /// An approximation of a black body's color, from 1000 K to 40000 K.
    static func rgb(kelvin: Double) -> Gain {
        let t = min(max(kelvin, 1000), 40000) / 100
        let red = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let green = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let blue = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        func unit(_ v: Double) -> Double { min(max(v, 0), 255) / 255 }
        return Gain(red: unit(red), green: unit(green), blue: unit(blue))
    }
}

/// Whether macOS Night Shift is shifting the colors right now. It is one
/// switch for every screen.
struct NightShiftStatus: Equatable {
    var isOn: Bool
}
