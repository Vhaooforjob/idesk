import AppKit
import Combine
import CoreGraphics
import Foundation

/// Brightness and color of the external screens, and Night Shift.
///
/// Brightness uses the screen's own backlight (DDC/CI) when it answers.
/// Otherwise it darkens what macOS sends with a gamma table. Warmth is
/// always a gamma table, so it works on every screen. Night Shift is one
/// macOS switch for all screens.
@MainActor
final class ScreenTuningViewModel: ObservableObject {
    struct Screen: Identifiable, Equatable {
        let id: CGDirectDisplayID
        var name: String
        var uuid: String?
        var control: BrightnessControl
        /// 0...1: the backlight, or the software level.
        var brightness: Double
        var warmth: Double

        var usesHardware: Bool {
            if case .hardware = control { return true }
            return false
        }

        /// A backlight can go to its lowest level; software dimming keeps a floor.
        var brightnessRange: ClosedRange<Double> {
            usesHardware ? 0...1 : ScreenColor.minimumBrightness...1
        }
    }

    /// How much a brightness shortcut moves the slider: 5%.
    static let keyStep = 0.05

    @Published private(set) var screens: [Screen] = []
    @Published private(set) var nightShift: NightShiftStatus?

    private let displays: DisplaysViewModel
    private let settingsStore: SettingsStore
    private let system: ScreenTuningSystem
    private let dialogs: DialogPresenting
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var generation = 0
    /// Screens whose gamma table iDesk changed, so they get it back.
    private var tinted: Set<CGDirectDisplayID> = []
    private var pendingWrites: [CGDirectDisplayID: Int] = [:]
    private var writers: [CGDirectDisplayID: Task<Void, Never>] = [:]

    init(displays: DisplaysViewModel, settingsStore: SettingsStore, system: ScreenTuningSystem, dialogs: DialogPresenting) {
        self.displays = displays
        self.settingsStore = settingsStore
        self.system = system
        self.dialogs = dialogs
        nightShift = system.nightShiftStatus()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: Lifecycle

    func start(notifications: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        displays.$displays.removeDuplicates()
            .sink { [weak self] _ in Task { await self?.reload() } }
            .store(in: &cancellables)
        // A screen that wakes has lost its gamma table, and its DDC channel
        // takes a moment to answer.
        let names: [(NotificationCenter, Notification.Name)] = [
            (notifications, NSWorkspace.didWakeNotification),
            (notifications, NSWorkspace.screensDidWakeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        ]
        for (center, name) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    await self?.reload()
                }
            })
        }
    }

    /// Gives the screens their own colors back, for example when iDesk quits.
    func stop() {
        guard !tinted.isEmpty else { return }
        system.restoreColors()
        tinted = []
    }

    // MARK: Reading

    var externals: [DisplayInfo] { displays.displays.filter { !$0.isBuiltin && $0.isEnabled } }
    var hasNightShift: Bool { nightShift != nil }

    /// Looks at the screens again: which can be dimmed in hardware, at what
    /// level, and puts the saved colors back.
    func reload() async {
        generation += 1
        let current = generation
        let candidates = externals
        system.prepareHardware(for: candidates.map(\.id))
        var result: [Screen] = []
        for display in candidates {
            let uuid = system.identifier(for: display.id)
            let tuning = uuid.flatMap { settingsStore.value.screenTuning[$0] } ?? ScreenTuning()
            let level = await system.hardwareBrightness(of: display.id)
            guard current == generation else { return }
            if let level {
                result.append(Screen(id: display.id, name: display.name, uuid: uuid, control: .hardware(maximum: level.maximum),
                                     brightness: Double(level.value) / Double(level.maximum), warmth: tuning.warmth))
            } else {
                result.append(Screen(id: display.id, name: display.name, uuid: uuid, control: .software,
                                     brightness: tuning.softwareBrightness, warmth: tuning.warmth))
            }
        }
        guard current == generation else { return }
        screens = result
        for screen in result { applyColors(of: screen) }
        // Screens that went away have nothing left to restore.
        tinted.formIntersection(result.map(\.id))
        refreshNightShift()
    }

    func refreshNightShift() {
        nightShift = system.nightShiftStatus()
    }

    // MARK: Intents

    /// `level` is 0...1 on the slider.
    func setBrightness(_ level: Double, for id: CGDirectDisplayID) {
        guard let index = screens.firstIndex(where: { $0.id == id }) else { return }
        switch screens[index].control {
        case let .hardware(maximum):
            let fraction = min(max(level, 0), 1)
            screens[index].brightness = fraction
            pendingWrites[id] = Int((fraction * Double(maximum)).rounded())
            drainWrites(for: id)
        case .software:
            let fraction = min(max(level, ScreenColor.minimumBrightness), 1)
            screens[index].brightness = fraction
            remember(screens[index])
            applyColors(of: screens[index])
        }
    }

    /// Brightens or dims one screen from a shortcut: the one under the
    /// pointer when it is an external screen, otherwise the first one.
    func nudgeBrightness(by delta: Double, near id: CGDirectDisplayID?) {
        guard let screen = screens.first(where: { $0.id == id }) ?? screens.first else { return }
        let range = screen.brightnessRange
        setBrightness(min(max(screen.brightness + delta, range.lowerBound), range.upperBound), for: screen.id)
    }

    func toggleNightShift() {
        refreshNightShift()
        guard let status = nightShift else { return }
        setNightShift(!status.isOn)
    }

    func setWarmth(_ warmth: Double, for id: CGDirectDisplayID) {
        guard let index = screens.firstIndex(where: { $0.id == id }) else { return }
        screens[index].warmth = min(max(warmth, 0), 1)
        remember(screens[index])
        applyColors(of: screens[index])
    }

    /// Back to the colors macOS sends. A hardware backlight keeps its level.
    func resetColors(for id: CGDirectDisplayID) {
        guard let index = screens.firstIndex(where: { $0.id == id }) else { return }
        screens[index].warmth = 0
        if !screens[index].usesHardware { screens[index].brightness = 1 }
        remember(screens[index])
        applyColors(of: screens[index])
    }

    func setNightShift(_ on: Bool) {
        let accepted = system.setNightShift(on)
        refreshNightShift()
        guard !accepted || nightShift?.isOn != on else { return }
        dialogs.showError(String(localized: "Could not change Night Shift"),
                          WorkspaceFeatureError(message: String(localized: "macOS did not accept the change. It may be following its schedule.")))
    }

    /// Waits for the hardware writes in flight. Tests use it.
    func settle() async {
        for task in Array(writers.values) { await task.value }
    }

    // MARK: Writing

    /// One write at a time per screen, and only the newest level: dragging
    /// a slider sends many values but the screen only needs the last ones.
    private func drainWrites(for id: CGDirectDisplayID) {
        guard writers[id] == nil else { return }
        writers[id] = Task { [weak self] in
            while let self, let value = self.pendingWrites.removeValue(forKey: id) {
                let written = await self.system.setHardwareBrightness(value, of: id)
                if !written { self.fallBackToSoftware(id) }
            }
            self?.writers[id] = nil
        }
    }

    /// A screen that stops answering still gets a working slider.
    private func fallBackToSoftware(_ id: CGDirectDisplayID) {
        pendingWrites[id] = nil
        guard let index = screens.firstIndex(where: { $0.id == id }) else { return }
        let saved = screens[index].uuid.flatMap { settingsStore.value.screenTuning[$0] } ?? ScreenTuning()
        screens[index].control = .software
        screens[index].brightness = saved.softwareBrightness
        applyColors(of: screens[index])
    }

    private func remember(_ screen: Screen) {
        guard let uuid = screen.uuid else { return }
        let tuning = ScreenTuning(softwareBrightness: screen.usesHardware ? 1 : screen.brightness, warmth: screen.warmth)
        var settings = settingsStore.value
        settings.screenTuning[uuid] = tuning.isNeutral ? nil : tuning
        if settings != settingsStore.value { settingsStore.value = settings }
    }

    private func applyColors(of screen: Screen) {
        let tuning = ScreenTuning(softwareBrightness: screen.usesHardware ? 1 : screen.brightness, warmth: screen.warmth)
        // A screen nobody tuned keeps whatever table other apps set.
        guard !tuning.isNeutral || tinted.contains(screen.id) else { return }
        system.applyGain(ScreenColor.gain(brightness: tuning.softwareBrightness, warmth: tuning.warmth), to: screen.id)
        if tuning.isNeutral { tinted.remove(screen.id) } else { tinted.insert(screen.id) }
    }
}
