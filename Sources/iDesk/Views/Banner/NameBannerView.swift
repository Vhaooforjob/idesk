import SwiftUI

/// A sign that drops on its strings and swings, or a glass pill in the
/// middle of the screen, with the name of the desktop just arrived on.
struct NameBannerView: View {
    @ObservedObject var viewModel: NameBannerViewModel
    @State private var swing: Double = 0

    var body: some View {
        GeometryReader { geometry in
            switch viewModel.style {
            case .hangingSign:
                sign
                    .rotationEffect(.degrees(swing), anchor: .top)
                    .offset(y: viewModel.isShown ? 0 : -260)
                    .opacity(viewModel.isShown ? 1 : 0)
                    .animation(viewModel.isShown ? .spring(response: 0.5, dampingFraction: 0.62) : .easeIn(duration: 0.3), value: viewModel.isShown)
                    .frame(width: geometry.size.width, alignment: .top)
                    .onChange(of: viewModel.tick) { _, _ in
                        swing = 14
                        withAnimation(.interpolatingSpring(stiffness: 40, damping: 3)) { swing = 0 }
                    }
            case .pill:
                pill
                    .scaleEffect(viewModel.isShown ? 1 : 0.82)
                    .opacity(viewModel.isShown ? 1 : 0)
                    .blur(radius: viewModel.isShown ? 0 : 6)
                    .animation(viewModel.isShown ? .spring(response: 0.38, dampingFraction: 0.7) : .easeIn(duration: 0.25), value: viewModel.isShown)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.42)
            case .none:
                EmptyView()
            }
        }
    }

    /// A board on two strings meeting at one nail just under the menu bar.
    private var sign: some View {
        VStack(spacing: -4) {
            ZStack(alignment: .top) {
                SignStrings()
                    .stroke(Color(white: 0.92), lineWidth: 1.3)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                Circle()
                    .fill(RadialGradient(colors: [.white, Color(white: 0.55)], center: .topLeading, startRadius: 0, endRadius: 8))
                    .frame(width: 9, height: 9)
                    .offset(y: -3)
            }
            .frame(width: 220, height: 64)
            board
        }
        .padding(.top, 6)
    }

    private var board: some View {
        VStack(spacing: 2) {
            Text(viewModel.name)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if !viewModel.subtitle.isEmpty {
                Text(viewModel.subtitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 16)
        .frame(minWidth: 260, maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.45)))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(LinearGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        .environment(\.colorScheme, .dark)
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 18, weight: .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.name)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if !viewModel.subtitle.isEmpty {
                    Text(viewModel.subtitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
    }
}

/// Two strings from one nail down to the board's top corners.
private struct SignStrings: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 40, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - 40, y: rect.maxY))
        return path
    }
}
