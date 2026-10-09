import AppKit
import Combine

/// The state of the Desktop Line: which desktops hang, how they look and
/// move, and whether the line is down. Its window and views read it and
/// send intents back.
@MainActor
final class DesktopLineViewModel: ObservableObject {
    struct Celebration: Equatable {
        var id = ""
        var tick = 0
    }

    @Published private(set) var items: [HangingDesktop] = []
    @Published private(set) var look = LineLook()
    @Published private(set) var visibility: LineVisibility = .onHover
    /// Whether the line has slid down into view.
    @Published private(set) var isRevealed = false
    /// Counts puffs of wind: every card swings a little on each.
    @Published private(set) var gust = 0
    /// The card that should play the switch effect.
    @Published private(set) var celebration = Celebration()
    @Published var pressedID: String?

    /// Card frames in panel coordinates, reported by the views. The panel
    /// only catches clicks over cards and lets the rest through.
    var hitRects: [String: CGRect] = [:]

    /// The Settings preview: always down, sample desktops, and clicks only
    /// play the effect.
    let isPreview: Bool
    /// The shortcut or the menu asked to show or hide the line.
    let toggleRequests = PassthroughSubject<Void, Never>()
    /// The active Space changed: the window checks for full screen apps.
    let spaceChanges = PassthroughSubject<Void, Never>()

    private let desktops: DesktopsViewModel?
    private var screen: NSScreen?
    private var gustTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(desktops: DesktopsViewModel) {
        self.desktops = desktops
        isPreview = false
        let settings = desktops.settings
        look = LineLook(settings)
        visibility = settings.visibility

        desktops.changes
            .sink { [weak self] in self?.rebuild() }
            .store(in: &cancellables)
        desktops.settingsChanges
            .sink { [weak self] value in self?.apply(value) }
            .store(in: &cancellables)
        desktops.highlights
            .sink { [weak self] id in self?.celebrate(id) }
            .store(in: &cancellables)
        desktops.arrivals
            .sink { [weak self] _ in
                self?.rebuild()
                self?.spaceChanges.send()
            }
            .store(in: &cancellables)
        scheduleGust()
    }

    /// A line of sample desktops that follows the look in the settings.
    init(preview items: [HangingDesktop], settings: AnyPublisher<AppSettings, Never>) {
        desktops = nil
        isPreview = true
        self.items = items
        settings
            .sink { [weak self] value in self?.look = LineLook(value) }
            .store(in: &cancellables)
    }

    private func apply(_ settings: AppSettings) {
        let newLook = LineLook(settings)
        if newLook != look { look = newLook }
        if settings.visibility != visibility { visibility = settings.visibility }
    }

    // MARK: Intents from the cards

    func select(_ space: DesktopSpace) {
        guard let desktops else { return celebrate(space.id) }
        desktops.go(to: space)
    }

    func rename(_ space: DesktopSpace) {
        guard let desktops else { return celebrate(space.id) }
        desktops.rename(space)
    }

    func resetName(_ space: DesktopSpace) {
        desktops?.resetName(space)
    }

    func canDelete(_ space: DesktopSpace) -> Bool {
        desktops?.canDelete(space) ?? false
    }

    func delete(_ space: DesktopSpace) {
        guard let desktops else { return }
        Task { await desktops.delete(space) }
    }

    /// Adds a desktop on the display the line hangs on.
    func addDesktop() {
        guard let desktops else { return }
        Task { await desktops.addDesktop(onDisplay: items.first?.space.displayID) }
    }

    // MARK: Intents from the menu, shortcuts and Settings

    func toggle() {
        toggleRequests.send()
    }

    func blow() {
        gust += 1
    }

    func celebrate(_ id: String) {
        celebration = Celebration(id: id, tick: celebration.tick + 1)
    }

    /// Plays the switch effect on a sample card other than the current one.
    func playEffect() {
        if let item = items.filter({ !$0.space.isCurrent }).randomElement() ?? items.first { celebrate(item.id) }
    }

    // MARK: Intents from the window

    /// The line is about to come down on a screen: hang that screen's
    /// desktops and refresh the picture of the one showing.
    func prepare(for screen: NSScreen) {
        self.screen = screen
        rebuild()
        desktops?.refreshPreview(on: screen)
    }

    func setRevealed(_ revealed: Bool) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
    }

    func isFullScreen(_ screen: NSScreen) -> Bool {
        desktops?.currentSpace(on: screen)?.kind == .fullScreen
    }

    // MARK: Private

    private func rebuild() {
        guard let desktops, let screen = screen ?? SpaceService.screenUnderPointer else { return }
        let fresh = desktops.hangingDesktops(on: screen)
        if fresh != items { items = fresh }
    }

    /// Windy days have gusts: every few seconds the whole line swings.
    private func scheduleGust() {
        gustTimer?.invalidate()
        let timer = Timer(timeInterval: .random(in: 3.5...7), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isRevealed && self.look.sway == .windy { self.blow() }
                self.scheduleGust()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        gustTimer = timer
    }
}
