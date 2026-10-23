import AppKit
import Combine

@MainActor
final class WindowRuleService: ObservableObject {
    @Published private(set) var lastError: String?
    var hasPermission: () -> Bool = { PermissionService.canSwitchDesktops }
    private var reportedPermissionError = false
    private let store: SettingsStore
    private let desktops: DesktopsViewModel
    private let suspended: () -> Bool
    private var task: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private var seen = Set<String>()
    private var pending: [String: Date] = [:]
    private var needsBaseline = true
    private var sleeping = false
    private let events = WindowEventObserver()
    private var scanning = false

    init(store: SettingsStore, desktops: DesktopsViewModel, suspended: @escaping () -> Bool) {
        self.store = store
        self.desktops = desktops
        self.suspended = suspended
    }

    func start() {
        store.$value.map(\.windowRules).removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.restart() }.store(in: &observers)
        let center = NSWorkspace.shared.notificationCenter
        center.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
            self?.sleeping = true
        }.store(in: &observers)
        center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            self?.sleeping = false
            self?.needsBaseline = true
        }.store(in: &observers)
    }

    func stop() { task?.cancel(); task = nil; events.stop(); observers.removeAll() }

    private func restart() {
        task?.cancel()
        events.stop()
        needsBaseline = true
        pending = [:]
        lastError = nil
        guard store.value.windowRules.contains(where: \.isEnabled) else { task = nil; return }
        events.onChange = { [weak self] in await self?.scan() }
        events.start()
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.events.refresh()
                await self?.scan()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    static func matchingRule(for window: WindowCandidate, rules: [WindowRule]) -> WindowRule? {
        rules.first { $0.isEnabled && $0.bundleID == window.bundleID &&
            ($0.titleContains.isEmpty || window.title.localizedStandardContains($0.titleContains)) }
    }

    func scan() async {
        guard !sleeping, !scanning else { return }
        scanning = true
        defer { scanning = false }
        guard !suspended() else { needsBaseline = true; return }
        guard hasPermission() else {
            reportedPermissionError = true
            lastError = String(localized: "Allow Accessibility to enable window rules."); return
        }
        if reportedPermissionError { lastError = nil; reportedPermissionError = false }
        guard !desktops.isMovingWindow else { return }
        do {
            desktops.reload()
            let windows = try await desktops.windowsForMove()
            try Task.checkCancellation()
            let key: (WindowCandidate) -> String = { "\($0.selection.processID):\($0.id)" }
            let current = Set(windows.map(key))
            if needsBaseline { seen = current; needsBaseline = false; return }
            seen.formIntersection(current)
            pending = pending.filter { current.contains($0.key) }
            for window in windows where !window.isMinimized && !seen.contains(key(window)) {
                try Task.checkCancellation()
                let id = key(window)
                pending[id] = pending[id] ?? Date()
                guard let rule = Self.matchingRule(for: window, rules: store.value.windowRules) else {
                    if Date().timeIntervalSince(pending[id]!) > 12 { seen.insert(id); pending[id] = nil }
                    continue
                }
                guard !suspended(), !desktops.isMovingWindow else { return }
                seen.insert(id)
                pending[id] = nil
                guard let destination = desktops.spaces.first(where: { $0.id == rule.desktopID && $0.kind == .desktop }) else {
                    lastError = rule.appName + ": " + String(localized: "Desktop unavailable"); continue
                }
                do {
                    try await desktops.placeWindow(window.selection, on: destination)
                    desktops.journal.record("Window Rule", item: "Window #\(window.id)")
                } catch {
                    lastError = rule.appName + ": " + error.localizedDescription
                    desktops.journal.record("Window Rule", item: "Window #\(window.id)", error: error)
                }
            }
        } catch is CancellationError { return }
        catch { lastError = error.localizedDescription }
    }
}
