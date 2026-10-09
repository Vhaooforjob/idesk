import AppKit
import Combine

/// The desktop's name shown for a moment after switching.
@MainActor
final class NameBannerViewModel: ObservableObject {
    @Published private(set) var name = ""
    @Published private(set) var subtitle = ""
    @Published private(set) var style: NameBannerStyle = .hangingSign
    /// The screen to show it on.
    @Published private(set) var screen: NSScreen?
    /// Whether the banner's window is on screen.
    @Published private(set) var isPresented = false
    /// Whether the banner itself is in, rather than on its way in or out.
    @Published private(set) var isShown = false
    /// Changes on every switch so the entrance plays again.
    @Published private(set) var tick = 0

    private let desktops: DesktopsViewModel
    private var hideWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    static let visibleFor: TimeInterval = 1.5
    static let exitDuration: TimeInterval = 0.5

    init(desktops: DesktopsViewModel) {
        self.desktops = desktops
        desktops.arrivals
            .sink { [weak self] space in self?.show(space) }
            .store(in: &cancellables)
    }

    func show(_ space: DesktopSpace) {
        let style = desktops.settings.banner
        guard style != .none, space.kind == .desktop else { return }
        let name = desktops.name(for: space)
        self.name = name
        subtitle = name == space.defaultName ? "" : space.defaultName
        self.style = style
        screen = DesktopsViewModel.screen(for: space.displayID) ?? SpaceService.screenUnderPointer
        // Start from the hidden pose so every switch replays the entrance.
        isShown = false
        isPresented = true
        DispatchQueue.main.async { [weak self] in
            self?.tick += 1
            self?.isShown = true
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleFor, execute: work)
    }

    private func hide() {
        isShown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration) { [weak self] in
            guard let self, !self.isShown else { return }
            self.isPresented = false
        }
    }
}
