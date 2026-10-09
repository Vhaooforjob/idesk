import Combine
import CoreGraphics
import Foundation

/// Which screens are on, for example while streaming: all of them, only
/// the main screen, or only one external screen. What each screen shows is
/// left to macOS.
@MainActor
final class DisplaysViewModel: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var arrangement: DisplayArrangement = .allOn

    /// How long a new setup waits for "Keep" before undoing itself.
    static let confirmSeconds = 15

    private let service: DisplayControlling
    private let dialogs: DialogPresenting
    private var cancellables: Set<AnyCancellable> = []

    init(service: DisplayControlling, dialogs: DialogPresenting) {
        self.service = service
        self.dialogs = dialogs
        service.displaysPublisher
            .sink { [weak self] displays in self?.update(displays) }
            .store(in: &cancellables)
    }

    private func update(_ displays: [DisplayInfo]) {
        self.displays = displays
        if let primary = primaryID {
            arrangement = DisplayArrangement.current(of: displays, primary: primary)
        }
    }

    // MARK: Reading

    var primaryID: CGDirectDisplayID? {
        DisplayArrangement.primary(of: displays, menuBarDisplay: service.menuBarDisplay)
    }

    var primary: DisplayInfo? { displays.first { $0.id == primaryID } }
    var externals: [DisplayInfo] { displays.filter { $0.id != primaryID } }
    var hasSeveralDisplays: Bool { displays.count > 1 }
    var canTurnOff: Bool { service.canTurnOff }
    var hasScreensOff: Bool { displays.contains { !$0.isEnabled } }

    /// At least one screen always stays on: the last one cannot be turned
    /// off, here or anywhere else.
    func canToggle(_ display: DisplayInfo) -> Bool {
        !display.isEnabled || displays.filter(\.isEnabled).count > 1
    }

    /// The arrangements worth offering: one "only this external screen"
    /// per external screen.
    var arrangements: [DisplayArrangement] {
        guard canTurnOff else { return [] }
        return [.allOn, .mainOnly] + externals.map { .externalOnly($0.id) }
    }

    func title(for arrangement: DisplayArrangement) -> String {
        guard case let .externalOnly(id) = arrangement, externals.count > 1,
              let name = displays.first(where: { $0.id == id })?.name else { return arrangement.title }
        return String(localized: "Only \(name)")
    }

    // MARK: Intents

    func choose(_ arrangement: DisplayArrangement) {
        guard let primary = primaryID, let layout = arrangement.layout(for: displays, primary: primary) else { return }
        apply(layout)
    }

    /// Turns one screen on or off; the others stay as they are.
    func setEnabled(_ display: DisplayInfo, _ enabled: Bool) {
        var layout = service.currentLayout
        if enabled { layout.enabled.insert(display.id) } else { layout.enabled.remove(display.id) }
        apply(layout)
    }

    /// Every screen on. Goes straight to the safe state, whatever the
    /// screens are doing now.
    func turnEverythingOn() {
        do {
            try service.recoverAll()
        } catch {
            dialogs.showError(String(localized: "Could not change the screens"), error)
        }
    }

    func refresh() {
        service.refresh()
    }

    /// Applies a layout. One that turns a screen off must be confirmed
    /// within a few seconds, or it undoes itself: the dialog may be on a
    /// screen that just went dark.
    private func apply(_ layout: DisplayLayout) {
        let previous = service.currentLayout
        guard layout != previous else { return }
        guard !layout.enabled.isEmpty else {
            return dialogs.showError(String(localized: "Could not change the screens"), DisplayError.noScreenLeft)
        }
        do {
            try service.apply(layout)
        } catch {
            // Never leave the screens half changed.
            try? service.recoverAll()
            return dialogs.showError(String(localized: "Could not change the screens"), error)
        }
        let turnsSomethingOff = !previous.enabled.isSubset(of: layout.enabled)
        guard turnsSomethingOff, !dialogs.confirmKeepDisplays(seconds: Self.confirmSeconds) else { return }
        do {
            try service.apply(previous)
        } catch {
            try? service.recoverAll()
            dialogs.showError(String(localized: "Could not change the screens"), error)
        }
    }
}
