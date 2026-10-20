import Carbon
import Foundation
import Combine

/// System-wide shortcuts through Carbon, as in iSnap's GlobalHotkeyService.
@MainActor
final class HotkeyService: ObservableObject {
    enum Action: UInt32 { case toggleLine = 1, renameCurrent = 2, restoreDisplays = 3, moveWindow = 4, searchDesktops = 5, previousDesktop = 6 }

    @Published private(set) var errors: [Action: String] = [:]
    static let recordingChanged = Notification.Name("iDeskShortcutRecordingChanged")
    private var recording = false
    private var shortcuts: [Action: String] = [:]
    private var observer: AnyCancellable?

    var onAction: ((Action) -> Void)?

    private var references: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x6944534B // iDSK

    init() {
        observer = NotificationCenter.default.publisher(for: Self.recordingChanged)
            .sink { [weak self] note in
                guard let self else { return }
                self.recording = note.object as? Bool ?? false
                self.register(self.shortcuts)
            }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    if let action = Action(rawValue: identifier.id) { service.onAction?(action) }
                }
                return noErr
            },
            1,
            &event,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
    }

    deinit {
        references.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        if let handler { RemoveEventHandler(handler) }
    }

    func register(_ shortcuts: [Action: String]) {
        self.shortcuts = shortcuts
        references.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        references.removeAll()
        errors = Self.validationErrors(shortcuts)
        guard !recording else { return }
        for (action, shortcut) in shortcuts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where errors[action] == nil {
            register(shortcut, action: action)
        }
    }

    private func register(_ shortcut: String, action: Action) {
        guard let parsed = Self.parse(shortcut) else { return }
        var reference: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: signature, id: action.rawValue)
        guard RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotkeyID, GetApplicationEventTarget(), 0, &reference) == noErr else {
            errors[action] = String(localized: "This shortcut could not be registered. Choose another combination.")
            return
        }
        references.append(reference)
    }

    static func validationErrors(_ shortcuts: [Action: String]) -> [Action: String] {
        var errors: [Action: String] = [:]
        var owners: [String: [Action]] = [:]
        for (action, value) in shortcuts where !value.isEmpty {
            guard let parsed = parse(value) else {
                errors[action] = String(localized: "Use modifiers and one key, for example ⌃⌥M.")
                continue
            }
            owners["\(parsed.keyCode):\(parsed.modifiers)", default: []].append(action)
        }
        for actions in owners.values where actions.count > 1 {
            for action in actions { errors[action] = String(localized: "This shortcut is used by another iDesk action.") }
        }
        return errors
    }

    static func keyName(for code: UInt16) -> String? {
        keyCodes.first { $0.value == UInt32(code) }?.key
    }

    static func shortcuts(in settings: AppSettings) -> [Action: String] {
        [.toggleLine: settings.toggleLineHotkey, .renameCurrent: settings.renameHotkey,
         .restoreDisplays: settings.restoreDisplaysHotkey, .moveWindow: settings.moveWindowHotkey,
         .searchDesktops: settings.searchDesktopsHotkey, .previousDesktop: settings.previousDesktopHotkey]
    }

    /// Reads shortcuts written like "⌃⌥D" or "ctrl+option+D".
    static func parse(_ value: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let tokens = value
            .replacingOccurrences(of: "⌘", with: " cmd ")
            .replacingOccurrences(of: "⌃", with: " ctrl ")
            .replacingOccurrences(of: "⌥", with: " option ")
            .replacingOccurrences(of: "⇧", with: " shift ")
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "+-")))
            .filter { !$0.isEmpty }
        var modifiers: UInt32 = 0
        var key: String?
        for token in tokens {
            switch token.lowercased() {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "option", "alt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default:
                guard key == nil else { return nil }
                key = token.uppercased()
            }
        }
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0, let key, let keyCode = keyCodes[key] else { return nil }
        return (keyCode, modifiers)
    }

    private static let keyCodes: [String: UInt32] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16,
        "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
        "9": 25, "7": 26, "8": 28, "0": 29, "]": 30, "O": 31, "U": 32,
        "[": 33, "I": 34, "P": 35, "L": 37, "J": 38, "'": 39, "K": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "N": 45, "M": 46, ".": 47, "SPACE": 49,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
        "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111
    ]
}
