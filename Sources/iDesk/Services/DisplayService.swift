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

/// Turning a screen off uses the window server's private
/// `CGSConfigureDisplayEnabled`, as display utilities do. iDesk never
/// changes what a screen shows or its resolution. Changes last for this
/// login session only, so logging out brings every screen back.
@MainActor
final class DisplayService: DisplayControlling, ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []

    /// Screens turned off by iDesk. macOS may stop listing them, so iDesk
    /// remembers them to turn them back on.
    private var turnedOff: [CGDirectDisplayID: DisplayInfo] = [:]
    /// Names seen while a screen was on; a switched off screen has no
    /// NSScreen to ask.
    private var names: [CGDirectDisplayID: String] = [:]
    private var observer: NSObjectProtocol?

    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let configureEnabled: ConfigureEnabled? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureEnabled.self)
    }()

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var displaysPublisher: AnyPublisher<[DisplayInfo], Never> { $displays.eraseToAnyPublisher() }
    var menuBarDisplay: CGDirectDisplayID { CGMainDisplayID() }
    var canTurnOff: Bool { Self.configureEnabled != nil }

    var currentLayout: DisplayLayout {
        DisplayLayout(enabled: Set(displays.filter(\.isEnabled).map(\.id)))
    }

    func refresh() {
        for screen in NSScreen.screens { names[screen.displayID] = screen.localizedName }
        let online = Self.onlineDisplays()
        var fresh = online.map { id in
            DisplayInfo(
                id: id,
                name: name(for: id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                // A screen copying another, when the user mirrors in System
                // Settings, reports itself inactive, yet it is on.
                isEnabled: turnedOff[id] == nil
                    && (CGDisplayIsActive(id) != 0 || CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay)
            )
        }
        for (id, info) in turnedOff where !online.contains(id) {
            fresh.append(DisplayInfo(id: id, name: info.name, isBuiltin: info.isBuiltin, isEnabled: false))
        }
        fresh.sort { ($0.isBuiltin ? 0 : 1, $0.id) < ($1.isBuiltin ? 0 : 1, $1.id) }
        if fresh != displays { displays = fresh }
    }

    func apply(_ layout: DisplayLayout) throws {
        guard !layout.enabled.isEmpty else { throw DisplayError.noScreenLeft }
        guard let configureEnabled = Self.configureEnabled else { throw DisplayError.cannotTurnOff }
        let toEnable = displays.filter { layout.enabled.contains($0.id) && !$0.isEnabled }.map(\.id)
        let toDisable = displays.filter { !layout.enabled.contains($0.id) && $0.isEnabled }
        log.notice("Screens on: \(layout.enabled.sorted(), privacy: .public)")

        // Screens come on before others go off, so one is always lit.
        if !toEnable.isEmpty {
            try configure { config in
                for id in toEnable { try Self.check(configureEnabled(config, id, true)) }
            }
            for id in toEnable { turnedOff[id] = nil }
        }
        if !toDisable.isEmpty {
            try configure { config in
                for display in toDisable { try Self.check(configureEnabled(config, display.id, false)) }
            }
            for display in toDisable { turnedOff[display.id] = display }
        }
        refresh()
    }

    func recoverAll() throws {
        log.notice("Turning every screen back on")
        // Screens iDesk turned off, and any online screen that is dark
        // without being a mirror copy.
        let dark = Set(turnedOff.keys).union(Self.onlineDisplays().filter {
            CGDisplayIsActive($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay
        })
        defer { refresh() }
        guard !dark.isEmpty, let configureEnabled = Self.configureEnabled else { return }
        try configure { config in
            for id in dark { try Self.check(configureEnabled(config, id, true)) }
        }
        turnedOff.removeAll()
    }

    /// Turns back on every screen iDesk turned off, for example on quit.
    func turnEverythingBackOn() {
        do {
            try recoverAll()
        } catch {
            log.error("Could not turn screens back on: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Private

    private func name(for id: CGDirectDisplayID) -> String {
        if let name = names[id] { return name }
        return CGDisplayIsBuiltin(id) != 0 ? String(localized: "Built-in Display") : String(localized: "External Display")
    }

    private func configure(_ body: (CGDisplayConfigRef?) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try Self.check(CGBeginDisplayConfiguration(&config))
        do {
            try body(config)
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
