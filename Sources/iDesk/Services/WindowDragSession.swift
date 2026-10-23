import AppKit
import UniformTypeIdentifiers

@MainActor
final class WindowDragSession {
    static let shared = WindowDragSession()
    static let type = NSPasteboard.PasteboardType("dev.idesk.window-selection")
    private var token: String?
    private var expires = Date.distantPast
    private var windows: [WindowSelection] = []
    private var allowed: Set<String> = []
    var onBegin: (() -> Void)?
    var isDragging: Bool { token != nil && Date() < expires && NSEvent.pressedMouseButtons != 0 }
    func begin(windows: [WindowCandidate], destinations: [WindowDestination]) -> NSItemProvider {
        let provider = NSItemProvider()
        guard !windows.isEmpty, !windows.contains(where: \.isMinimized), !destinations.isEmpty else { return provider }
        let value = UUID().uuidString
        token = value; expires = Date().addingTimeInterval(60)
        self.windows = windows.map(\.selection); allowed = Set(destinations.map(\.id))
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.rawValue, visibility: .ownProcess) { completion in
            completion(Data(value.utf8), nil); return nil
        }
        onBegin?()
        return provider
    }
    func accepts(_ pasteboard: NSPasteboard, destination: String) -> Bool {
        guard Date() < expires, allowed.contains(destination), let token,
              let data = pasteboard.data(forType: Self.type), String(data: data, encoding: .utf8) == token else { return false }
        return true
    }
    func take(_ pasteboard: NSPasteboard, destination: String) -> [WindowSelection]? {
        guard accepts(pasteboard, destination: destination) else { return nil }
        let result = windows; token = nil; windows = []; allowed = []
        return result
    }
}
