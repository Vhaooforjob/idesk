import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet { scheduleSave() }
    }

    @Published private(set) var saveError: String?
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    /// App Intents queries must not move a corrupt file or initialize controllers.
    static func readForQueries() -> AppSettings {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: base.appendingPathComponent("iDesk/settings.json")),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    convenience init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDesk", isDirectory: true)
        self.init(fileURL: base.appendingPathComponent("settings.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
                value = decoded
            } else {
                // Starting from defaults would overwrite the names on the
                // next save, so keep the unreadable file beside it.
                Self.keepUnreadableCopy(of: fileURL)
                value = AppSettings()
            }
        } else {
            value = AppSettings()
        }
    }

    /// Where an unreadable settings file is kept: `settings.json.bak`.
    static func backupURL(for fileURL: URL) -> URL {
        fileURL.appendingPathExtension("bak")
    }

    private static func keepUnreadableCopy(of fileURL: URL) {
        let backup = backupURL(for: fileURL)
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }

    func saveNow() throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            throw error
        }
    }

    func retrySave() { try? saveNow() }

    func replace(with settings: AppSettings) throws {
        let previous = value
        value = settings
        do { try saveNow() }
        catch { value = previous; throw error }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            try? self?.saveNow()
        }
    }
}
