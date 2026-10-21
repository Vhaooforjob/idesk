import AppKit
import Combine

// The window server knows every Space on every display. These calls are
// private but long stable, need no permission, and are what window managers
// and iSnap's full screen detection rely on.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

/// Keeps an up-to-date list of Spaces. macOS announces a switch, but not a
/// desktop being added, removed or reordered in Mission Control, so the list
/// is also re-read every couple of seconds while the screens are awake; the
/// call is cheap, but there is nothing to see while they sleep.
@MainActor
final class SpaceService: ObservableObject {
    @Published private(set) var spaces: [DesktopSpace] = []

    /// Called after the active Space changed, with the list already updated.
    var onActiveSpaceChange: (() -> Void)?

    private let read: () -> [DesktopSpace]
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    var isPolling: Bool { timer != nil }

    /// - Parameter read: where the Spaces come from; the window server by
    ///   default, a fixed list in tests.
    init(read: @escaping () -> [DesktopSpace] = { SpaceService.read() }) {
        self.read = read
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
                self?.onActiveSpaceChange?()
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pausePolling() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumePolling() }
        })
        resumePolling()
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Stops the periodic re-read, for while the screens sleep.
    func pausePolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Starts the periodic re-read, after one now to catch up with whatever
    /// changed while it was paused.
    func resumePolling() {
        guard timer == nil else { return }
        reload()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reload() {
        let fresh = read()
        if fresh != spaces { spaces = fresh }
    }

    nonisolated static func read() -> [DesktopSpace] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] else { return [] }
        return SpaceLayout.parse(displays)
    }

    /// The Spaces shown on a screen. With "Displays have separate Spaces"
    /// off, every screen shows the same ones.
    func spaces(on screen: NSScreen?) -> [DesktopSpace] {
        let displays = Set(spaces.map(\.displayID))
        guard displays.count > 1 else { return spaces }
        if let screen, let uuid = Self.displayIdentifier(for: screen) {
            let matching = spaces.filter { $0.displayID == uuid }
            if !matching.isEmpty { return matching }
        }
        let first = spaces.first?.displayID
        return spaces.filter { $0.displayID == first }
    }

    func currentSpace(on screen: NSScreen?) -> DesktopSpace? {
        spaces(on: screen).first(where: \.isCurrent)
    }

    static func displayIdentifier(for screen: NSScreen) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(screen.displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static var screenUnderPointer: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
}
