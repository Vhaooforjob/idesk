import AppKit
import Carbon
import CoreGraphics

/// A keyboard shortcut iDesk can press on the user's behalf.
struct KeyShortcut: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    /// The modifiers in the form Carbon shortcuts use, without the Fn bit
    /// macOS adds to arrow keys.
    var carbonModifiers: UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    func post() {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// The Mission Control shortcuts from System Settings → Keyboard →
/// Keyboard Shortcuts, read from `com.apple.symbolichotkeys`, so iDesk
/// presses whatever keys the user actually has.
enum SymbolicHotkeys {
    static let moveLeftID = 79
    static let moveRightID = 81
    /// "Switch to Desktop 1"; Desktop N is this plus N - 1, up to 16.
    static let firstDesktopID = 118

    static func table() -> [String: Any]? {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
    }

    enum Entry: Equatable {
        /// On. Without a saved key the shortcut is still the system default.
        case enabled(KeyShortcut?)
        case disabled
        case missing
    }

    static func entry(_ id: Int, in table: [String: Any]?) -> Entry {
        guard let entry = table?[String(id)] as? [String: Any] else { return .missing }
        guard (entry["enabled"] as? NSNumber)?.boolValue == true else { return .disabled }
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count >= 3 else { return .enabled(nil) }
        guard parameters[1] != 0xFFFF else { return .disabled }
        // The modifier mask uses the same bits as CGEventFlags.
        return .enabled(KeyShortcut(keyCode: CGKeyCode(parameters[1]), flags: CGEventFlags(rawValue: UInt64(parameters[2]))))
    }

    /// ⌃1 to ⌃9, the keys macOS offers for "Switch to Desktop 1" to 9.
    private static let digitKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// "Switch to Desktop N", only when the user turned it on.
    static func desktop(_ number: Int, in table: [String: Any]? = table()) -> KeyShortcut? {
        guard (1...16).contains(number), case let .enabled(shortcut) = entry(firstDesktopID + number - 1, in: table) else { return nil }
        if let shortcut { return shortcut }
        guard number <= digitKeyCodes.count else { return nil }
        return KeyShortcut(keyCode: digitKeyCodes[number - 1], flags: .maskControl)
    }

    /// Every Mission Control shortcut for switching desktops that is on.
    /// iDesk presses these itself, so an iDesk shortcut on the same keys
    /// would answer its own presses.
    static func switching(in table: [String: Any]? = table()) -> [KeyShortcut] {
        let steps = [move(right: false, in: table), move(right: true, in: table)]
        return (steps + (1...16).map { desktop($0, in: table) }).compactMap { $0 }
    }

    /// ⌃← and ⌃→ are on unless the user turned them off.
    static func move(right: Bool, in table: [String: Any]? = table()) -> KeyShortcut? {
        let standard = KeyShortcut(keyCode: right ? 124 : 123, flags: [.maskControl, .maskSecondaryFn])
        switch entry(right ? moveRightID : moveLeftID, in: table) {
        case let .enabled(shortcut): return shortcut ?? standard
        case .disabled: return nil
        case .missing: return standard
        }
    }
}

/// Switches desktops the only way macOS allows an app to: by pressing the
/// Mission Control shortcuts. "Switch to Desktop N" jumps straight there
/// when it is on; otherwise iDesk walks with ⌃← / ⌃→ and checks after
/// each Space change until it arrives.
@MainActor
protocol SpaceSwitching: AnyObject {
    func go(to space: DesktopSpace) -> SpaceSwitcher.Outcome
    func spaceDidChange()
}

@MainActor
final class SpaceSwitcher: SpaceSwitching {
    enum Outcome { case switching, alreadyThere, needsPermission, noShortcut }

    /// Called when a switch was asked for but the desktop never became
    /// current: the shortcuts were ignored, or went to another display.
    var onFailure: ((DesktopSpace) -> Void)?

    private let spaces: SpaceService
    /// The desktop the latest request is heading for, until it arrives or
    /// the wait for it ends.
    private var requestedID: String?
    private var targetID: String?
    private var deadline = Date.distantPast
    private var pressesInFlight = 0
    /// Where the last walk started. Arriving there again means the presses
    /// went to another display, so the walk stops instead of looping.
    private var walkedFrom: String?

    init(spaces: SpaceService) {
        self.spaces = spaces
    }

    func go(to space: DesktopSpace) -> Outcome {
        guard !space.isCurrent else { return .alreadyThere }
        guard PermissionService.canSwitchDesktops else {
            PermissionService.logState()
            return .needsPermission
        }
        if let number = space.number, let shortcut = SymbolicHotkeys.desktop(number) {
            targetID = nil
            shortcut.post()
            expectArrival(at: space, within: Self.directTimeout)
            return .switching
        }
        guard SymbolicHotkeys.move(right: true) != nil, SymbolicHotkeys.move(right: false) != nil else { return .noShortcut }
        targetID = space.id
        walkedFrom = nil
        deadline = Date().addingTimeInterval(Self.walkTimeout)
        walk()
        expectArrival(at: space, within: Self.walkTimeout + 0.5)
        return .switching
    }

    private static let directTimeout: TimeInterval = 2.5
    private static let walkTimeout: TimeInterval = 5

    func expectArrival(at space: DesktopSpace, within seconds: TimeInterval) {
        requestedID = space.id
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.confirmArrival(at: space)
        }
    }

    /// Reports a failure unless the desktop is current by now, or a newer
    /// request has replaced this one.
    func confirmArrival(at space: DesktopSpace) {
        guard requestedID == space.id else { return }
        requestedID = nil
        spaces.reload()
        guard let fresh = spaces.spaces.first(where: { $0.id == space.id }), !fresh.isCurrent else { return }
        onFailure?(fresh)
    }

    /// Called after every Space change: keep walking until there.
    func spaceDidChange() {
        guard targetID != nil, pressesInFlight == 0 else { return }
        walk()
    }

    private func walk() {
        guard let targetID, Date() < deadline,
              let goal = spaces.spaces.first(where: { $0.id == targetID }),
              let current = spaces.spaces.first(where: { $0.displayID == goal.displayID && $0.isCurrent }),
              current.id != goal.id, current.id != walkedFrom,
              let shortcut = SymbolicHotkeys.move(right: goal.position > current.position) else {
            self.targetID = nil
            return
        }
        // Mission Control queues quick presses and skips the in-between
        // animations, so the whole distance is pressed at once.
        let steps = abs(goal.position - current.position)
        walkedFrom = current.id
        pressesInFlight = steps
        for step in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.07 * Double(step)) { [weak self] in
                shortcut.post()
                self?.pressesInFlight -= 1
            }
        }
    }
}
