import AppKit
import SwiftUI

// The Desktop Line's visuals and gestures. The rope, clips, swing, breeze
// and hover reveal follow iSnap's Capture Line, itself adapted from
// Tendedero (https://github.com/alejandrobujan/tendedero), whose license
// requires this notice to stay with the adapted code:
//
// Copyright (c) 2026 Alejandro Buján
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit
// persons to whom the Software is furnished to do so, subject to the
// following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
// NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
// USE OR OTHER DEALINGS IN THE SOFTWARE.

struct DesktopLineView: View {
    @ObservedObject var viewModel: DesktopLineViewModel
    /// Off only when rendering to an image, which cannot draw AppKit views.
    var isInteractive = true

    /// The Settings preview keeps the line down and never tucks it away.
    private var revealed: Bool { viewModel.isPreview || viewModel.isRevealed }

    /// Only redraw every frame when something actually moves on its own.
    private var animates: Bool {
        revealed && (viewModel.look.sway != .still || viewModel.look.particles != .none
            || viewModel.look.style == .fairyLights || viewModel.look.style == .bunting)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let count = viewModel.items.count
            let scale = LineLayout.scale(count: count, width: width)
            let xs = (0..<count).map { LineLayout.x(index: $0, count: count, width: width) }

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .topLeading) {
                    LineDecor(style: viewModel.look.style, sway: viewModel.look.sway, width: width, cardXs: xs,
                              cardHalfWidth: LineLayout.cardWidth * scale / 2, time: time)

                    if viewModel.items.isEmpty {
                        Text("No desktops yet")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .position(x: width / 2, y: 50)
                    }

                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                        let x = xs[index]
                        let hanger = LineLayout.hanger(viewModel.look.style, index: index)
                        let top = LineLayout.hangY(viewModel.look.style, x: x, width: width) - hanger.above
                        let height = LineLayout.panelHeight - top
                        HangingDesktopView(item: item, index: index, hanger: hanger, time: time, isInteractive: isInteractive, viewModel: viewModel)
                            .scaleEffect(scale, anchor: .top)
                            .frame(width: LineLayout.cardWidth, height: height, alignment: .top)
                            .position(x: x, y: top + height / 2)
                    }

                    ParticleLayer(style: viewModel.look.particles, time: time)
                        .frame(width: width, height: LineLayout.panelHeight)
                        .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: viewModel.items.map(\.id))
            .animation(.easeInOut(duration: 0.35), value: viewModel.look.style)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: revealed ? 0 : -(LineLayout.panelHeight + 12))
            .animation(
                revealed ? .spring(response: 0.42, dampingFraction: 0.82) : .easeIn(duration: 0.22),
                value: revealed
            )
        }
        .coordinateSpace(name: DesktopLineView.space)
        .onPreferenceChange(LineHitRectsKey.self) { rects in
            viewModel.hitRects = rects
        }
    }

    static let space = "desktopLine"
}

/// One desktop with its hanger: it drops onto the line, swings, sways with
/// the breeze, and plays the switch effect when you arrive on it.
private struct HangingDesktopView: View {
    let item: HangingDesktop
    let index: Int
    let hanger: LineLayout.Hanger
    let time: Double
    let isInteractive: Bool
    @ObservedObject var viewModel: DesktopLineViewModel

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hovering = false
    @State private var hop: CGFloat = 0
    @State private var pop: CGFloat = 1
    @State private var spin: Double = 0
    @State private var glow = false

    private var style: HangStyle { viewModel.look.style }
    private var isCurrent: Bool { item.space.isCurrent }
    private var pressed: Bool { viewModel.pressedID == item.id }

    var body: some View {
        VStack(spacing: -hanger.overlap) {
            HangerView(style: style, hanger: hanger, index: index, isCurrent: isCurrent)
                .frame(width: LineLayout.cardWidth, height: hanger.height)
                .zIndex(1)
            card
        }
        .rotationEffect(.degrees(angle), anchor: .top)
        .offset(y: (arrived ? 0 : -50) + hop)
        .opacity(arrived ? 1 : 0)
        .onAppear(perform: arrive)
        .onChange(of: viewModel.gust) { _, _ in breeze() }
        .onChange(of: viewModel.isRevealed) { _, now in if now { drop() } }
        .onChange(of: viewModel.celebration) { _, celebration in
            if celebration.id == item.id { celebrate() }
        }
        .onChange(of: style) { _, _ in nudge(8) }
    }

    /// The resting tilt, the spring of the last nudge, and the idle sway.
    private var angle: Double {
        let tiltScale: Double = switch style {
        case .frames: 0.5
        case .rail: 0.3
        default: 1
        }
        return item.tilt * tiltScale + swing + idleSway
    }

    private var idleSway: Double {
        let phase = Double(index) * 1.3 + item.tilt
        // Longer strings swing slower, as pendulums do.
        let pace = style == .strings ? sqrt(44 / Double(hanger.length + 20)) : 1
        switch viewModel.look.sway {
        case .still: return 0
        case .gentle: return 0.9 * sin(time * 0.9 * pace + phase)
        case .windy:
            return 1.4 + 2.4 * sin(time * 1.6 * pace + phase) + 1.1 * sin(time * 2.9 * pace + phase * 2.1)
        }
    }

    private var card: some View {
        let photo = LineLayout.photoSize(aspect: item.thumbnail.map { $0.size.width / max($0.size.height, 1) } ?? item.aspect)
        return VStack(spacing: 0) {
            DesktopPhoto(item: item, size: photo, radius: chrome.photoRadius)
            caption
                .frame(width: photo.width, height: LineLayout.captionHeight)
        }
        .padding([.top, .horizontal], chrome.padding)
        .padding(.bottom, chrome == .polaroid ? 4 : 0)
        .background(CardChromeBackground(chrome: chrome))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: chrome.radius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-1.5)
            }
        }
        .shadow(color: glowColor.opacity(glow ? 0.9 : 0), radius: glow ? 22 : 0)
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.18), radius: hovering ? 14 : 9, y: hovering ? 8 : 5)
        .rotation3DEffect(.degrees(spin), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .scaleEffect((pressed ? 0.95 : (hovering ? 1.04 : 1)) * pop, anchor: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
        .overlay(alignment: .topTrailing) {
            // Drawn here, clicked through CardClickArea, which sits on top.
            Image(systemName: "pencil")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 20, height: 20)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.6))
                .padding(4)
                .opacity(hovering ? 1 : 0)
                .scaleEffect(hovering ? 1 : 0.6)
                .allowsHitTesting(false)
        }
        .overlay {
            if isInteractive { CardClickArea(item: item, viewModel: viewModel) }
        }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: LineHitRectsKey.self,
                    value: [item.id: geometry.frame(in: .named(DesktopLineView.space))]
                )
            }
        )
    }

    private var caption: some View {
        HStack(spacing: 5) {
            if let number = item.space.number {
                Text("\(number)")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(isCurrent ? Color.white : chrome.captionColor.opacity(0.85))
                    .frame(minWidth: 16, minHeight: 16)
                    .background(isCurrent ? Color.accentColor : chrome.captionColor.opacity(0.14), in: Circle())
            } else {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(chrome.captionColor.opacity(0.85))
                    .frame(width: 16, height: 16)
                    .background(chrome.captionColor.opacity(0.14), in: Circle())
            }
            Text(item.name)
                .font(chrome.captionFont)
                .foregroundStyle(chrome.captionColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var chrome: CardChrome {
        switch style {
        case .clothesline, .rail: .glass
        case .fairyLights: .night
        case .strings, .bunting: .polaroid
        case .frames: .wood
        }
    }

    private var glowColor: Color {
        style == .fairyLights ? Color(red: 1, green: 0.82, blue: 0.45) : .accentColor
    }

    // MARK: Motion

    private func arrive() {
        swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72).delay(Double(index) * 0.05)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6).delay(Double(index) * 0.05)) { swing = 0 }
    }

    /// The line slid down: each card swings in turn, as if just let go.
    private func drop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(index)) {
            nudge(viewModel.look.sway == .still ? 3 : 6)
        }
    }

    private func breeze() {
        let strength: ClosedRange<Double> = viewModel.look.sway == .windy ? 3.5...6.5 : 1.6...3.4
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 0...0.35)) {
            nudge(.random(in: strength))
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }

    private func celebrate() {
        switch viewModel.look.effect {
        case .none:
            return
        case .swing:
            nudge(14)
        case .bounce:
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                hop = 16
                pop = 1.1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.32)) {
                    hop = 0
                    pop = 1
                }
            }
        case .spin:
            withAnimation(.easeInOut(duration: 0.9)) { spin += 360 }
            nudge(5)
        case .glow:
            withAnimation(.easeOut(duration: 0.3)) { glow = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeInOut(duration: 0.8)) { glow = false }
            }
            nudge(4)
        }
    }
}

/// The desktop's picture, or a placeholder until it has been visited.
private struct DesktopPhoto: View {
    let item: HangingDesktop
    let size: CGSize
    let radius: CGFloat

    var body: some View {
        Group {
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: placeholderColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: item.space.kind == .desktop ? "menubar.dock.rectangle" : "macwindow")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var placeholderColors: [Color] {
        let hue = HangingDesktop.hue(for: item.id)
        return [Color(hue: hue, saturation: 0.55, brightness: 0.85), Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 0.6)]
    }
}

struct LineHitRectsKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Gestures

/// Click switches to the desktop, the pencil in the top-right corner renames
/// it, and right-click opens its menu. AppKit handles the mouse so clicks
/// work in a panel that never becomes key.
private struct CardClickArea: NSViewRepresentable {
    let item: HangingDesktop
    let viewModel: DesktopLineViewModel

    func makeNSView(context: Context) -> CardClickView {
        let view = CardClickView()
        configure(view)
        return view
    }

    func updateNSView(_ view: CardClickView, context: Context) {
        configure(view)
    }

    private func configure(_ view: CardClickView) {
        let space = item.space
        let id = item.id
        let viewModel = viewModel
        view.onClick = { viewModel.select(space) }
        view.onRename = { viewModel.rename(space) }
        view.onPressChange = { viewModel.pressedID = $0 ? id : nil }
        view.menuProvider = {
            let menu = NSMenu()
            if !space.isCurrent {
                menu.addItem(LineMenuItem(String(localized: "Go to This Desktop")) { viewModel.select(space) })
            }
            menu.addItem(LineMenuItem(String(localized: "Rename…")) { viewModel.rename(space) })
            menu.addItem(LineMenuItem(String(localized: "Use Default Name")) { viewModel.resetName(space) })
            menu.addItem(.separator())
            menu.addItem(LineMenuItem(String(localized: "Add Desktop")) { viewModel.addDesktop() })
            let delete = LineMenuItem(String(localized: "Delete Desktop…")) { viewModel.delete(space) }
            delete.isEnabled = viewModel.canDelete(space)
            menu.autoenablesItems = false
            menu.addItem(delete)
            return menu
        }
    }
}

final class CardClickView: NSView {
    /// A card's menu is open: the line must not tuck away underneath it.
    static var isShowingMenu = false

    var onClick: () -> Void = {}
    var onRename: () -> Void = {}
    var onPressChange: (Bool) -> Void = { _ in }
    var menuProvider: () -> NSMenu = { NSMenu() }

    private var isPressing = false
    private static let cornerSize: CGFloat = 28

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var renameCorner: NSRect {
        NSRect(
            x: bounds.width - Self.cornerSize,
            y: isFlipped ? 0 : bounds.height - Self.cornerSize,
            width: Self.cornerSize,
            height: Self.cornerSize
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if renameCorner.contains(point) {
            onRename()
            return
        }
        isPressing = true
        onPressChange(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressing else { return }
        isPressing = false
        onPressChange(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = menuProvider()
        Self.isShowingMenu = true
        defer { Self.isShowingMenu = false }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class LineMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
