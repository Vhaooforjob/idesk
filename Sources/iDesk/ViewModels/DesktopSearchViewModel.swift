import Combine
import Foundation

@MainActor
final class DesktopSearchViewModel: ObservableObject {
    struct Entry: Identifiable {
        let space: DesktopSpace
        let name: String
        let displayName: String
        var appearance = DesktopAppearance()
        var id: String { space.id }
    }

    @Published var query = "" { didSet { reconcile() } }
    @Published var selectedID: String?
    @Published private(set) var entries: [Entry] = []
    private let read: () -> [Entry]
    private var cancellables: Set<AnyCancellable> = []

    init(read: @escaping () -> [Entry]) { self.read = read }

    convenience init(desktops: DesktopsViewModel) {
        self.init {
            desktops.spacesByDisplay.enumerated().flatMap { index, group in
                group.spaces.filter { $0.kind == .desktop || desktops.settings.showsFullScreenSpaces }.map {
                    Entry(space: $0, name: desktops.name(for: $0),
                          displayName: String(localized: "Display \(index + 1)"),
                          appearance: desktops.settings.appearances[$0.id] ?? DesktopAppearance())
                }
            }
        }
        desktops.changes.sink { [weak self] in self?.refresh() }.store(in: &cancellables)
    }

    var filtered: [Entry] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            let text = "\(entry.name) \(entry.space.defaultName) \(entry.displayName)"
            return tokens.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    var selection: DesktopSpace? { filtered.first { $0.id == selectedID }?.space }

    func open() { query = ""; refresh(); selectedID = filtered.first(where: { !$0.space.isCurrent })?.id ?? filtered.first?.id }
    func refresh() { entries = read(); reconcile() }
    func step(_ offset: Int) {
        guard !filtered.isEmpty else { return }
        let index = filtered.firstIndex { $0.id == selectedID } ?? 0
        selectedID = filtered[min(max(index + offset, 0), filtered.count - 1)].id
    }
    private func reconcile() {
        if !filtered.contains(where: { $0.id == selectedID }) { selectedID = filtered.first?.id }
    }
}
