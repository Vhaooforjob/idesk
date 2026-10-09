import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet { scheduleSave() }
    }

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    convenience init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iDesk", isDirectory: true)
        self.init(fileURL: base.appendingPathComponent("settings.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = decoded
        } else {
            value = AppSettings()
        }
    }

    func saveNow() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
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
