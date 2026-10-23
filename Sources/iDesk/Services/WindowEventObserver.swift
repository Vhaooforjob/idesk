import AppKit
import ApplicationServices

/// AX registrations belong to individual applications and windows. Unsupported
/// notifications are harmless: the rule service retains a polling fallback.
@MainActor
final class WindowEventObserver {
    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var coalescing: Task<Void, Never>?
    var onChange: (() async -> Void)?
    private var active = false
    deinit {
        coalescing?.cancel()
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
    func start() {
        guard !active else { return }
        active = true
        refresh()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceTokens.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(); self?.changed() }
            })
        }
    }
    func stop() {
        active = false; coalescing?.cancel(); coalescing = nil
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers = [:]
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; workspaceTokens = []
    }
    func refresh() {
        guard active, AXIsProcessTrusted() else { return }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let pids = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !pids.contains(pid) {
            if let observer = observers.removeValue(forKey: pid) { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        }
        for app in apps {
            let pid = app.processIdentifier
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.2)
            if observers[pid] == nil {
                var value: AXObserver?
                let result = AXObserverCreate(pid, { _, _, _, context in
                    guard let context else { return }
                    // Callback is installed on the main run loop; the owner removes
                    // the source before releasing observers or callback context.
                    MainActor.assumeIsolated { Unmanaged<WindowEventObserver>.fromOpaque(context).takeUnretainedValue().changed() }
                }, &value)
                guard result == .success, let value else { continue }
                observers[pid] = value
                _ = AXObserverAddNotification(value, element, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(value), .commonModes)
            }
            guard let observer = observers[pid] else { continue }
            var windows: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
                  let list = windows as? [AXUIElement] else { continue }
            for window in list {
                for notification in [kAXTitleChangedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                    _ = AXObserverAddNotification(observer, window, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
                }
            }
        }
    }
    func changed() {
        guard active else { return }
        coalescing?.cancel()
        coalescing = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.active else { return }
            // Only debounce work that has not started. A new notification must
            // not cancel verification of a window move already sent to macOS.
            self.coalescing = nil
            self.refresh()
            await self.onChange?()
        }
    }
}
