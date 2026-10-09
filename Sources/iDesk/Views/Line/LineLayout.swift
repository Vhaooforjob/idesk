import CoreGraphics

/// Where everything sits on the line, per hanging style.
enum LineLayout {
    static let panelHeight: CGFloat = 232
    static let cardWidth: CGFloat = 150
    static let spacing: CGFloat = 172
    static let ropeTop: CGFloat = 12
    static let inset: CGFloat = 5
    static let captionHeight: CGFloat = 25
    static let cardRadius: CGFloat = 14

    /// What holds a card: how far it reaches above the hang point, how far
    /// the card hangs below it, and how much of it overlaps the card's top.
    struct Hanger: Equatable {
        let above: CGFloat
        let length: CGFloat
        let overlap: CGFloat

        var height: CGFloat { above + length + overlap }
    }

    static func hanger(_ style: HangStyle, index: Int) -> Hanger {
        switch style {
        case .clothesline, .bunting: Hanger(above: 9.5, length: 4.5, overlap: 12)
        case .fairyLights: Hanger(above: 4, length: 12, overlap: 2)
        case .strings: Hanger(above: 5, length: stringLengths[index % stringLengths.count], overlap: 0)
        case .frames: Hanger(above: 5, length: 28, overlap: 0)
        case .rail: Hanger(above: 9, length: 3, overlap: 9)
        }
    }

    /// Strings of different lengths, like a mobile.
    static let stringLengths: [CGFloat] = [24, 50, 34, 58, 40]

    /// How deep a rope sags in the middle; a rail and nails do not.
    static func sag(_ style: HangStyle, width: CGFloat) -> CGFloat {
        switch style {
        case .clothesline, .fairyLights: min(30, width * 0.018)
        case .bunting: min(18, width * 0.012)
        case .strings, .frames, .rail: 0
        }
    }

    static func ropeY(_ style: HangStyle, x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let fraction = x / width
        return ropeTop + 4 * sag(style, width: width) * fraction * (1 - fraction)
    }

    /// Where a card's hanger is fixed: the rope, a pin at the top edge, a
    /// nail, or the rail.
    static func hangY(_ style: HangStyle, x: CGFloat, width: CGFloat) -> CGFloat {
        switch style {
        case .clothesline, .fairyLights, .bunting: ropeY(style, x: x, width: width)
        case .strings: 6
        case .frames: 16
        case .rail: 16
        }
    }

    /// Cards move closer together, and shrink, when many desktops share a
    /// narrow screen.
    static func spacing(count: Int, width: CGFloat) -> CGFloat {
        min(spacing, (width - 60) / CGFloat(max(count, 1)))
    }

    static func scale(count: Int, width: CGFloat) -> CGFloat {
        min(1, spacing(count: count, width: width) / spacing)
    }

    static func x(index: Int, count: Int, width: CGFloat) -> CGFloat {
        let step = spacing(count: count, width: width)
        return width / 2 - CGFloat(max(count - 1, 0)) * step / 2 + CGFloat(index) * step
    }

    static func photoSize(aspect: CGFloat) -> CGSize {
        let width = cardWidth - inset * 2
        let height = min(100, max(64, width / max(aspect, 0.5)))
        return CGSize(width: width, height: height)
    }
}
