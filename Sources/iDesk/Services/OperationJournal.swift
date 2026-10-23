import AppKit
import Combine
import ApplicationServices

@MainActor
final class OperationJournal: ObservableObject {
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let operation: String
        let item: String
        let error: String?
        var retry: (() async -> Void)?
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var retrying: UUID?
    func record(_ operation: String, item: String, error: Error? = nil, retry: (() async -> Void)? = nil) {
        entries.insert(Entry(operation: operation, item: item, error: error?.localizedDescription, retry: retry), at: 0)
        if entries.count > 100 { entries.removeLast(entries.count - 100) }
    }
    func retry(_ entry: Entry) async {
        guard retrying == nil, let current = entries.first(where: { $0.id == entry.id }), let action = current.retry else { return }
        retrying = entry.id
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].retry = nil }
        await action()
        retrying = nil
    }
    func clear() { entries = [] }
    /// Export excludes window titles, names, URLs and user-provided error text.
    var diagnosticSummary: String {
        let symbols = ["SLSCopyManagedDisplaySpaces", "SLSMoveWindowsToManagedSpace", "SLSCopySpacesForWindows", "_AXUIElementGetWindow", "SLSSpaceSetCompatID", "SLSSetWindowListWorkspace"]
        let handle = dlopen(nil, RTLD_NOW)
        let availability = symbols.map { "\($0): \(dlsym(handle, $0) != nil ? "present" : "missing")" }.joined(separator: "\n")
        return "iDesk \((Bundle.main.bundleIdentifier == "dev.idesk.app" ? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String : nil) ?? "development")\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nAccessibility: \(AXIsProcessTrusted())\nScreen capture: \(PermissionService.canCapturePreviews)\nScreens: \(NSScreen.screens.count)\nReadable Spaces: \(SpaceService.read().count)\nMission Control left shortcut: \(SymbolicHotkeys.move(right: false) != nil)\nMission Control right shortcut: \(SymbolicHotkeys.move(right: true) != nil)\n\(availability)\nSymbol presence does not verify macOS operation support.\nOperations: \(entries.count); failures: \(entries.filter { $0.error != nil }.count)"
    }
}
