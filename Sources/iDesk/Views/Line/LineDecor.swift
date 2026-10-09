import SwiftUI

/// Cheerful colours for pins, magnets, pennants and bulbs.
enum Palette {
    static let bright: [Color] = [
        Color(red: 0.96, green: 0.36, blue: 0.36),
        Color(red: 0.99, green: 0.62, blue: 0.24),
        Color(red: 0.98, green: 0.82, blue: 0.27),
        Color(red: 0.36, green: 0.78, blue: 0.47),
        Color(red: 0.30, green: 0.62, blue: 0.96),
        Color(red: 0.66, green: 0.45, blue: 0.93)
    ]

    static let bulbs: [Color] = [
        Color(red: 1.00, green: 0.80, blue: 0.40),
        Color(red: 1.00, green: 0.45, blue: 0.45),
        Color(red: 0.45, green: 0.85, blue: 1.00),
        Color(red: 0.55, green: 1.00, blue: 0.60),
        Color(red: 1.00, green: 0.60, blue: 0.95)
    ]

    static func color(_ colors: [Color], _ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
}

// MARK: - Card frames

/// The card around each desktop's picture, matching the hanging style.
enum CardChrome: Equatable {
    case glass, night, polaroid, wood

    var padding: CGFloat {
        switch self {
        case .glass, .night: LineLayout.inset
        case .polaroid: 6
        case .wood: 7
        }
    }

    var radius: CGFloat {
        switch self {
        case .glass, .night: LineLayout.cardRadius
        case .polaroid: 3
        case .wood: 4
        }
    }

    var photoRadius: CGFloat {
        switch self {
        case .glass, .night: LineLayout.cardRadius - LineLayout.inset
        case .polaroid, .wood: 1.5
        }
    }

    var captionFont: Font {
        switch self {
        case .glass, .night: .system(size: 11, weight: .semibold, design: .rounded)
        case .polaroid: .custom("Marker Felt", size: 13)
        case .wood: .system(size: 11, weight: .semibold, design: .serif)
        }
    }

    var captionColor: Color {
        switch self {
        case .glass: .primary
        case .night: .white
        case .polaroid: Color(white: 0.18)
        case .wood: Color(red: 0.98, green: 0.92, blue: 0.80)
        }
    }
}

struct CardChromeBackground: View {
    let chrome: CardChrome

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: chrome.radius, style: .continuous)
        switch chrome {
        case .glass:
            // Crisp glass: the system blurred material with a thin specular edge.
            shape.fill(.ultraThinMaterial)
                .overlay(shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75
                ))
                .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
        case .night:
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.5)))
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.75))
        case .polaroid:
            shape.fill(Color(white: 0.98))
                .overlay(shape.stroke(Color.black.opacity(0.08), lineWidth: 0.5))
        case .wood:
            shape.fill(LinearGradient(
                colors: [
                    Color(red: 0.47, green: 0.29, blue: 0.16),
                    Color(red: 0.31, green: 0.18, blue: 0.09),
                    Color(red: 0.43, green: 0.26, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay(shape.inset(by: 2.5).stroke(Color(red: 0.88, green: 0.72, blue: 0.46).opacity(0.55), lineWidth: 1))
            .overlay(shape.stroke(Color.black.opacity(0.35), lineWidth: 0.8))
        }
    }
}

// MARK: - Hangers

/// What holds one card: a clip, a peg, a hook, a pinned thread, a nail with
/// its wire, or a magnet. Drawn from the hang point downwards.
struct HangerView: View {
    let style: HangStyle
    let hanger: LineLayout.Hanger
    let index: Int
    let isCurrent: Bool

    var body: some View {
        switch style {
        case .clothesline:
            Clip(colors: [0.70, 0.93, 0.82, 0.62].map { Color(white: $0) })
        case .bunting:
            Clip(colors: [
                Color(red: 0.72, green: 0.52, blue: 0.32),
                Color(red: 0.90, green: 0.74, blue: 0.52),
                Color(red: 0.80, green: 0.62, blue: 0.40),
                Color(red: 0.62, green: 0.44, blue: 0.26)
            ], spring: true)
        case .fairyLights, .strings, .frames, .rail:
            Canvas { context, size in draw(in: &context, size: size) }
                .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
                .allowsHitTesting(false)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: hanger.above)
        let bottom = size.height
        switch style {
        case .fairyLights:
            let ring = Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
            var stem = Path()
            stem.move(to: CGPoint(x: center.x, y: center.y + 3))
            stem.addLine(to: CGPoint(x: center.x, y: bottom))
            let brass = Color(red: 0.85, green: 0.68, blue: 0.35)
            context.stroke(ring, with: .color(brass), lineWidth: 1.4)
            context.stroke(stem, with: .color(brass), lineWidth: 1.4)
        case .strings:
            var thread = Path()
            thread.move(to: center)
            thread.addLine(to: CGPoint(x: center.x, y: bottom))
            context.stroke(thread, with: .color(Color(white: 0.92)), lineWidth: 1)
            context.stroke(thread, with: .color(.black.opacity(0.25)), lineWidth: 0.4)
            pin(at: center, radius: 4.5, color: Palette.color(Palette.bright, index), in: &context)
        case .frames:
            var wire = Path()
            wire.move(to: CGPoint(x: center.x - 38, y: bottom))
            wire.addLine(to: center)
            wire.addLine(to: CGPoint(x: center.x + 38, y: bottom))
            context.stroke(wire, with: .color(Color(white: 0.25)), lineWidth: 1.1)
            pin(at: center, radius: 3.2, color: Color(white: 0.62), in: &context)
        case .rail:
            pin(at: center, radius: 9, color: Palette.color(Palette.bright, index), in: &context)
        case .clothesline, .bunting:
            break
        }
    }

    /// A round head with a soft highlight: pin, nail or magnet.
    private func pin(at point: CGPoint, radius: CGFloat, color: Color, in context: inout GraphicsContext) {
        let head = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fill(head, with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.9), color, color.opacity(0.85)]),
            center: CGPoint(x: point.x - radius * 0.35, y: point.y - radius * 0.4),
            startRadius: 0,
            endRadius: radius * 1.3
        ))
        context.stroke(head, with: .color(.black.opacity(0.2)), lineWidth: 0.5)
    }
}

/// A brushed aluminium clip, or a wooden peg, with a slot where it grips
/// the rope. From iSnap's Capture Line.
private struct Clip: View {
    let colors: [Color]
    var spring = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(LinearGradient(
                stops: zip(colors, [0, 0.35, 0.65, 1]).map { .init(color: $0, location: $1) },
                startPoint: .leading,
                endPoint: .trailing
            ))
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)], startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.6
                    )
            )
            .overlay(alignment: .top) {
                if spring {
                    Capsule().fill(Color(white: 0.75)).frame(width: 11, height: 2.2).padding(.top, 11)
                } else {
                    Capsule().fill(Color.black.opacity(0.32)).frame(width: 5, height: 1.4).padding(.top, 8.5)
                }
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }
}

// MARK: - Rope, pennants, bulbs, rail

/// Everything that runs along the line behind the cards.
struct LineDecor: View {
    let style: HangStyle
    let sway: SwayStyle
    let width: CGFloat
    let cardXs: [CGFloat]
    let cardHalfWidth: CGFloat
    let time: Double

    var body: some View {
        Group {
            switch style {
            case .clothesline:
                Rope(path: ropePath, color: Color(white: 0.55))
            case .bunting:
                ZStack {
                    Canvas { context, _ in drawPennants(in: &context) }
                    Rope(path: ropePath, color: Color(red: 0.82, green: 0.74, blue: 0.62))
                }
            case .fairyLights:
                Canvas { context, _ in drawLights(in: &context) }
            case .rail:
                Rail(width: width)
            case .strings, .frames:
                Color.clear
            }
        }
        .frame(width: width, height: LineLayout.panelHeight)
        .allowsHitTesting(false)
    }

    private var ropePath: Path {
        Path { path in
            let top = LineLayout.ropeTop
            path.move(to: CGPoint(x: -20, y: top))
            path.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * LineLayout.sag(style, width: width))
            )
        }
    }

    private func isBehindCard(_ x: CGFloat) -> Bool {
        cardXs.contains { abs($0 - x) < cardHalfWidth + 6 }
    }

    private func drawPennants(in context: inout GraphicsContext) {
        let flutterSpeed = sway == .windy ? 3.4 : 1.6
        let flutterSize = sway == .windy ? 0.24 : (sway == .gentle ? 0.08 : 0)
        var index = 0
        var x: CGFloat = 14
        while x < width - 8 {
            defer {
                x += 30
                index += 1
            }
            guard !isBehindCard(x) else { continue }
            let y = LineLayout.ropeY(style, x: x, width: width)
            var flag = context
            flag.translateBy(x: x, y: y)
            flag.rotate(by: .radians(sin(time * flutterSpeed + Double(index) * 0.9) * flutterSize))
            var triangle = Path()
            triangle.move(to: CGPoint(x: -11, y: 0))
            triangle.addLine(to: CGPoint(x: 11, y: 0))
            triangle.addLine(to: CGPoint(x: 0, y: 26))
            triangle.closeSubpath()
            flag.fill(triangle, with: .color(Palette.color(Palette.bright, index)))
            flag.fill(triangle, with: .linearGradient(
                Gradient(colors: [Color.white.opacity(0.25), Color.clear]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: 26)
            ))
            flag.stroke(triangle, with: .color(.black.opacity(0.12)), lineWidth: 0.5)
        }
    }

    private func drawLights(in context: inout GraphicsContext) {
        context.stroke(ropePath, with: .color(Color(red: 0.12, green: 0.2, blue: 0.14).opacity(0.85)), lineWidth: 1.3)
        var bulbs: [(CGPoint, Color, Double)] = []
        var index = 0
        var x: CGFloat = 12
        while x < width {
            let y = LineLayout.ropeY(style, x: x, width: width)
            let wave = 0.5 + 0.5 * sin(time * 2.3 + Double(index) * 1.9)
            bulbs.append((CGPoint(x: x, y: y), Palette.color(Palette.bulbs, index), 0.45 + 0.55 * wave))
            x += 26
            index += 1
        }
        // The glow first, blurred in one layer, then the bulbs over it.
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 5))
            for (point, color, level) in bulbs {
                glow.fill(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 3, width: 18, height: 20)),
                          with: .color(color.opacity(0.55 * level)))
            }
        }
        for (point, color, level) in bulbs {
            context.fill(Path(CGRect(x: point.x - 2, y: point.y - 1, width: 4, height: 4)), with: .color(Color(white: 0.2)))
            let bulb = Path(ellipseIn: CGRect(x: point.x - 3.2, y: point.y + 2.5, width: 6.4, height: 9.5))
            context.fill(bulb, with: .color(color.opacity(0.55 + 0.45 * level)))
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.6, y: point.y + 4, width: 2, height: 3)),
                         with: .color(.white.opacity(0.7 * level)))
        }
    }
}

/// A thin neutral rope that reads on light and dark wallpapers alike and
/// fades out at both ends, as if it came from beyond the screen.
private struct Rope: View {
    let path: Path
    let color: Color

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(color, lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
        )
    }
}

/// A brushed steel rail with end caps, held just under the menu bar.
private struct Rail: View {
    let width: CGFloat

    var body: some View {
        let length = max(0, width - 48)
        ZStack {
            Capsule()
                .fill(LinearGradient(
                    stops: [
                        .init(color: Color(white: 0.92), location: 0),
                        .init(color: Color(white: 0.70), location: 0.5),
                        .init(color: Color(white: 0.55), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: length, height: 7)
                .overlay(Capsule().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
            HStack {
                cap
                Spacer()
                cap
            }
            .frame(width: length + 8)
        }
        .shadow(color: .black.opacity(0.3), radius: 2.5, y: 2)
        .position(x: width / 2, y: 16)
    }

    private var cap: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(white: 0.6), Color(white: 0.35)], startPoint: .top, endPoint: .bottom))
            .frame(width: 13, height: 13)
    }
}

// MARK: - Particles

/// Snow, sparkles, petals or leaves drifting down from the line. Every
/// particle is a pure function of time, so nothing needs to be stored.
struct ParticleLayer: View {
    let style: ParticleStyle
    let time: Double

    var body: some View {
        if style == .none {
            Color.clear
        } else {
            Canvas { context, size in
                context.addFilter(.shadow(color: .black.opacity(0.22), radius: 1, y: 0.5))
                switch style {
                case .snow: drawFalling(in: &context, size: size, count: 46, speed: 12...34, drift: 10, kind: .snow)
                case .petals: drawFalling(in: &context, size: size, count: 26, speed: 10...24, drift: 18, kind: .petal)
                case .leaves: drawFalling(in: &context, size: size, count: 22, speed: 14...30, drift: 26, kind: .leaf)
                case .sparkles: drawSparkles(in: &context, size: size)
                case .none: break
                }
            }
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.65),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
        }
    }

    private enum Kind { case snow, petal, leaf }

    /// A repeatable random number in 0..<1 for particle `i`, property `k`.
    private func random(_ i: Int, _ k: Int) -> Double {
        let value = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return value - floor(value)
    }

    private func drawFalling(in context: inout GraphicsContext, size: CGSize, count: Int,
                             speed: ClosedRange<Double>, drift: Double, kind: Kind) {
        let height = Double(size.height) + 20
        let width = Double(size.width)
        guard width > 0 else { return }
        for i in 0..<count {
            let fall = speed.lowerBound + random(i, 1) * (speed.upperBound - speed.lowerBound)
            let y = (time * fall + random(i, 2) * height).truncatingRemainder(dividingBy: height) - 10
            var x = random(i, 0) * width + sin(time * 0.7 + random(i, 3) * 6.28) * drift
            x = (x.truncatingRemainder(dividingBy: width) + width).truncatingRemainder(dividingBy: width)
            var piece = context
            piece.translateBy(x: x, y: y)
            switch kind {
            case .snow:
                let radius = 1 + random(i, 4) * 2.2
                piece.fill(Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
                           with: .color(.white.opacity(0.92)))
            case .petal:
                piece.rotate(by: .radians(time * (0.8 + random(i, 5)) + random(i, 6) * 6.28))
                let pink = random(i, 7) > 0.5 ? Color(red: 1, green: 0.74, blue: 0.82) : Color(red: 1, green: 0.88, blue: 0.92)
                piece.fill(Path(ellipseIn: CGRect(x: -4, y: -2.4, width: 8, height: 4.8)), with: .color(pink))
            case .leaf:
                piece.rotate(by: .radians(time * (1.2 + random(i, 5) * 1.5) + random(i, 6) * 6.28))
                let colors = [Color(red: 0.93, green: 0.45, blue: 0.16), Color(red: 0.85, green: 0.22, blue: 0.15),
                              Color(red: 0.96, green: 0.72, blue: 0.20), Color(red: 0.62, green: 0.38, blue: 0.18)]
                var leaf = Path()
                leaf.move(to: CGPoint(x: -6, y: 0))
                leaf.addQuadCurve(to: CGPoint(x: 6, y: 0), control: CGPoint(x: 0, y: -5))
                leaf.addQuadCurve(to: CGPoint(x: -6, y: 0), control: CGPoint(x: 0, y: 5))
                piece.fill(leaf, with: .color(colors[i % colors.count]))
            }
        }
    }

    private func drawSparkles(in context: inout GraphicsContext, size: CGSize) {
        for i in 0..<30 {
            let x = random(i, 0) * Double(size.width)
            let y = 6 + random(i, 1) * Double(size.height) * 0.7
            let phase = time * (1.4 + random(i, 2) * 2) + random(i, 3) * 6.28
            let s = pow(max(0, sin(phase)), 3) * (3 + random(i, 4) * 4)
            guard s > 0.2 else { continue }
            var star = Path()
            let inner = s * 0.28
            star.move(to: CGPoint(x: x, y: y - s))
            star.addLine(to: CGPoint(x: x + inner, y: y - inner))
            star.addLine(to: CGPoint(x: x + s, y: y))
            star.addLine(to: CGPoint(x: x + inner, y: y + inner))
            star.addLine(to: CGPoint(x: x, y: y + s))
            star.addLine(to: CGPoint(x: x - inner, y: y + inner))
            star.addLine(to: CGPoint(x: x - s, y: y))
            star.addLine(to: CGPoint(x: x - inner, y: y - inner))
            star.closeSubpath()
            let color = i % 3 == 0 ? Color(red: 1, green: 0.88, blue: 0.5) : Color.white
            context.fill(star, with: .color(color.opacity(0.95)))
        }
    }
}
