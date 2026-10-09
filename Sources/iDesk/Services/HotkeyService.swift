import Carbon
import Foundation

/// System-wide shortcuts through Carbon, as in iSnap's GlobalHotkeyService.
@MainActor
final class HotkeyService {
    enum Action: UInt32 { case toggleLine = 1, renameCurrent = 2, restoreDisplays = 3 }

    var onAction: ((Action) -> Void)?

    private var references: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x6944534B // iDSK

    init() {
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
        references.forEach { if let ref = $0 { UnregisterEventHotKey(ref) } }
        references.removeAll()
        for (action, shortcut) in shortcuts { register(shortcut, action: action) }
    }

    private func register(_ shortcut: String, action: Action) {
        guard let parsed = Self.parse(shortcut) else { return }
        var reference: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: signature, id: action.rawValue)
        guard RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotkeyID, GetApplicationEventTarget(), 0, &reference) == noErr else {
            return
        }
        references.append(reference)
    }

    /// Reads shortcuts written like "⌃⌥D" or "ctrl+option+D".
    static func parse(_ value: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        let lower = value.lowercased()
        if value.contains("⌘") || lower.contains("cmd") { modifiers |= UInt32(cmdKey) }
        if value.contains("⌃") || lower.contains("ctrl") || lower.contains("control") { modifiers |= UInt32(controlKey) }
        if value.contains("⌥") || lower.contains("option") || lower.contains("alt") { modifiers |= UInt32(optionKey) }
        if value.contains("⇧") || lower.contains("shift") { modifiers |= UInt32(shiftKey) }
        guard modifiers != 0 else { return nil }

        let key = value
            .replacingOccurrences(of: "⌘", with: " ")
            .replacingOccurrences(of: "⌃", with: " ")
            .replacingOccurrences(of: "⌥", with: " ")
            .replacingOccurrences(of: "⇧", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: " +-"))
            .filter { !$0.isEmpty && !["cmd", "ctrl", "control", "option", "alt", "shift"].contains($0.lowercased()) }
            .last?
            .uppercased()
        guard let key, let keyCode = keyCodes[key] else { return nil }
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
