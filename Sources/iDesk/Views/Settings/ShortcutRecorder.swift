import AppKit
import Combine
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: String

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.begin)
        button.setAccessibilityLabel(String(localized: "Record shortcut"))
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.value = value
        button.changed = { value = $0 }
        if !button.isRecording { button.title = value.isEmpty ? String(localized: "Record shortcut") : value }
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.end() }
}

final class RecorderButton: NSButton {
    var value = ""
    var changed: ((String) -> Void)?
    private(set) var isRecording = false
    private var monitor: Any?
    private var observers: Set<AnyCancellable> = []

    @objc func begin() {
        guard !isRecording else { end(); return }
        isRecording = true
        title = String(localized: "Press keys…")
        toolTip = String(localized: "Esc cancels. Delete clears the shortcut.")
        NotificationCenter.default.post(name: HotkeyService.recordingChanged, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            guard event.type == .keyDown else { self.end(); return event }
            self.record(event)
            return nil
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self] _ in self?.end() }.store(in: &observers)
        }
    }

    func record(_ event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 { end(); return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if event.keyCode == 51 && flags.isEmpty { changed?(""); value = ""; end(); return }
        guard !flags.intersection([.command, .control, .option]).isEmpty, let key = HotkeyService.keyName(for: event.keyCode) else {
            title = String(localized: "Use modifiers and a key")
            return
        }
        let text = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
        value = text
        changed?(text)
        end()
    }

    func end() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.removeAll()
        title = value.isEmpty ? String(localized: "Record shortcut") : value
        NotificationCenter.default.post(name: HotkeyService.recordingChanged, object: false)
    }
}
