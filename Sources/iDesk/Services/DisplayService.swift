import AppKit
import Combine
import CoreGraphics
import os

private let log = Logger(subsystem: "dev.idesk.app", category: "Displays")

/// Turns screens on and off, as view models need it.
@MainActor
protocol DisplayControlling: AnyObject {
    var displays: [DisplayInfo] { get }
    var displaysPublisher: AnyPublisher<[DisplayInfo], Never> { get }
    /// The screen with the menu bar right now.
    var menuBarDisplay: CGDirectDisplayID { get }
    /// False when this macOS cannot turn a screen off.
    var canTurnOff: Bool { get }
    var currentLayout: DisplayLayout { get }
    func apply(_ layout: DisplayLayout) throws
    /// The safe state: every screen on. Used after a failed change and by
    /// the "turn every screen back on" shortcut.
    func recoverAll() throws
    func refresh()
}

enum DisplayError: LocalizedError {
    case noScreenLeft
    case cannotTurnOff
    case failed(CGError)

    var errorDescription: String? {
        switch self {
        case .noScreenLeft: String(localized: "At least one screen has to stay on.")
        case .cannotTurnOff: String(localized: "This version of macOS does not let iDesk turn screens off.")
        case let .failed(error): String(localized: "macOS refused the screen change (error \(Int(error.rawValue))).")
        }
    }
}

/// The system boundary is injectable so hot-plug and failed configuration
/// sequences can be tested without changing the developer's screens.
@MainActor
protocol DisplaySystem: AnyObject {
    var menuBarDisplay: CGDirectDisplayID { get }
    var canTurnOff: Bool { get }
    func read() -> [DisplayInfo]
    func identifier(for id: CGDirectDisplayID) -> String?
    func setEnabled(_ ids: [CGDirectDisplayID], _ enabled: Bool) throws
}

/// Keeps the user's external-only preference separate from the temporary
/// fallback layout. The preference lasts until another choice or app exit.
@MainActor
final class DisplayService: DisplayControlling, ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []

    private struct ExternalPreference {
        let id: CGDirectDisplayID
        let uuid: String?
    }

    private let system: DisplaySystem
    /// Disabled displays can disappear from the online list. These are recovery
    /// candidates, never proof that a screen is connected or actually lit.
    private var turnedOff: [CGDirectDisplayID: DisplayInfo] = [:]
    private var online: [DisplayInfo] = []
    private var preferredExternal: ExternalPreference?
    private var changing = false
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private let observeChanges: Bool

    convenience init() {
        self.init(system: CoreGraphicsDisplaySystem())
    }

    init(system: DisplaySystem, observeChanges: Bool = true) {
        self.system = system
        self.observeChanges = observeChanges
        reload()
        guard observeChanges else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Never reconfigure inside a system notification/configuration call.
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Keep the recovery watchdog only while iDesk has a screen preference
    /// to recover. Normal all-screen use needs no periodic wakeups.
    private func updateRecoveryTimer() {
        guard observeChanges, preferredExternal != nil || !turnedOff.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate()
    }

    var displaysPublisher: AnyPublisher<[DisplayInfo], Never> { $displays.eraseToAnyPublisher() }
    var menuBarDisplay: CGDirectDisplayID { system.menuBarDisplay }
    var canTurnOff: Bool { system.canTurnOff }
    var currentLayout: DisplayLayout {
        DisplayLayout(enabled: Set(displays.filter(\.isEnabled).map(\.id)))
    }

    func refresh() {
        guard !changing else { return }
        changing = true
        defer { reload(); changing = false; updateRecoveryTimer() }
        reload()
        do {
            if let preferredExternal {
                let target = online.first { display in
                    guard !display.isBuiltin else { return false }
                    if let uuid = preferredExternal.uuid {
                        return system.identifier(for: display.id) == uuid
                    }
                    return display.id == preferredExternal.id
                }
                if let target {
                    try change(DisplayLayout(enabled: [target.id]))
                } else if let primary = DisplayArrangement.primary(of: displays, menuBarDisplay: menuBarDisplay) {
                    // Fallback does not overwrite the external-only preference.
                    try change(DisplayLayout(enabled: [primary]))
                }
            } else if !turnedOff.isEmpty && !online.contains(where: \.isEnabled) {
                try restoreAvailable()
            }
        } catch {
            log.error("Screen hot-plug recovery: \(error.localizedDescription, privacy: .public)")
            // Preserve the preference and retry on the next notification/tick.
            // A stale detached ID must not stop the built-in screen coming on.
            try? restoreAvailable()
        }
    }

    func apply(_ layout: DisplayLayout) throws {
        guard !layout.enabled.isEmpty else { throw DisplayError.noScreenLeft }
        changing = true
        defer { reload(); changing = false; updateRecoveryTimer() }
        reload()
        let primary = DisplayArrangement.primary(of: displays, menuBarDisplay: menuBarDisplay)
        let external = layout.enabled.count == 1
            ? displays.first { layout.enabled.contains($0.id) && $0.id != primary && !$0.isBuiltin }
            : nil
        let preference = external.map { ExternalPreference(id: $0.id, uuid: system.identifier(for: $0.id)) }
        try change(layout)
        preferredExternal = preference
    }

    func recoverAll() throws {
        // An explicit recovery cancels automatic restoration, including when
        // the fallback screen is already the only connected screen.
        preferredExternal = nil
        changing = true
        defer { reload(); changing = false; updateRecoveryTimer() }
        reload()
        try restoreAvailable()
    }

    func turnEverythingBackOn() {
        do { try recoverAll() }
        catch { log.error("Could not turn screens back on: \(error.localizedDescription, privacy: .public)") }
    }

    private func reload() {
        online = system.read()
        // macOS may have re-enabled a screen itself. Trust the actual state.
        for display in online where display.isEnabled { turnedOff[display.id] = nil }
        var fresh = online
        let ids = Set(online.map(\.id))
        for (id, info) in turnedOff where !ids.contains(id) {
            var info = info
            info.isEnabled = false
            fresh.append(info)
        }
        fresh.sort { ($0.isBuiltin ? 0 : 1, $0.id) < ($1.isBuiltin ? 0 : 1, $1.id) }
        if fresh != displays { displays = fresh }
    }

    private func change(_ layout: DisplayLayout) throws {
        guard !layout.enabled.isEmpty else { throw DisplayError.noScreenLeft }
        guard canTurnOff else { throw DisplayError.cannotTurnOff }
        guard layout.enabled.isSubset(of: Set(displays.map(\.id))) else { throw DisplayError.noScreenLeft }
        let active = Set(online.filter(\.isEnabled).map(\.id))
        let toEnable = layout.enabled.subtracting(active).sorted()
        for id in toEnable {
            try system.setEnabled([id], true)
            // Keep the recovery candidate until read() confirms it is on.
        }
        reload()
        // Successful CGCompleteDisplayConfiguration alone is not proof that a
        // newly attached screen is ready. Never darken the fallback until it is.
        guard online.contains(where: { layout.enabled.contains($0.id) && $0.isEnabled }) else {
            throw DisplayError.noScreenLeft
        }
        let toDisable = online.filter { !layout.enabled.contains($0.id) && $0.isEnabled }
        if !toDisable.isEmpty {
            log.notice("Screens on: \(layout.enabled.sorted(), privacy: .public)")
            // Remember recovery candidates before committing: even a failed
            // transaction may coincide with a hardware change. reload() drops
            // entries for screens that are still lit.
            for display in toDisable { turnedOff[display.id] = display }
            try system.setEnabled(toDisable.map(\.id), false)
        }
        reload()
        // Handle an unplug racing the disable transaction itself.
        if !online.contains(where: \.isEnabled) { try restoreAvailable() }
    }

    private func restoreAvailable() throws {
        var firstError: Error?
        // Each enable is its own transaction, built-in first: a disconnected
        // external ID cannot cancel recovery of the usable screens.
        let dark = displays.filter { !$0.isEnabled }
        for display in dark {
            do {
                try system.setEnabled([display.id], true)
            } catch {
                if display.isBuiltin || online.contains(where: { $0.id == display.id }) {
                    if firstError == nil { firstError = error }
                } else {
                    // It has gone away. Do not keep offering a phantom screen.
                    turnedOff[display.id] = nil
                }
                log.error("Could not enable screen \(display.id): \(error.localizedDescription, privacy: .public)")
            }
        }
        reload()
        if let firstError { throw firstError }
        if !dark.isEmpty && !online.contains(where: \.isEnabled) { throw DisplayError.noScreenLeft }
    }
}

/// Turning a screen off uses the window server's private API. Changes last
/// for this login session only, so logging out brings every screen back.
@MainActor
private final class CoreGraphicsDisplaySystem: DisplaySystem {
    private var names: [CGDirectDisplayID: String] = [:]
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let configureEnabled: ConfigureEnabled? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureEnabled.self)
    }()

    var menuBarDisplay: CGDirectDisplayID { CGMainDisplayID() }
    var canTurnOff: Bool { Self.configureEnabled != nil }

    func identifier(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    func read() -> [DisplayInfo] {
        for screen in NSScreen.screens { names[screen.displayID] = screen.localizedName }
        return Self.onlineDisplays().map { id in
            DisplayInfo(
                id: id,
                name: names[id] ?? (CGDisplayIsBuiltin(id) != 0
                    ? String(localized: "Built-in Display") : String(localized: "External Display")),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isEnabled: CGDisplayIsActive(id) != 0 || CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
            )
        }
    }

    func setEnabled(_ ids: [CGDirectDisplayID], _ enabled: Bool) throws {
        guard let configureEnabled = Self.configureEnabled else { throw DisplayError.cannotTurnOff }
        var config: CGDisplayConfigRef?
        try Self.check(CGBeginDisplayConfiguration(&config))
        do {
            for id in ids { try Self.check(configureEnabled(config, id, enabled)) }
        } catch {
            CGCancelDisplayConfiguration(config)
            throw error
        }
        try Self.check(CGCompleteDisplayConfiguration(config, .forSession))
    }

    private static func check(_ error: CGError) throws {
        guard error == .success else { throw DisplayError.failed(error) }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
