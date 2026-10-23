import AppKit
import Combine

struct WindowDestination: Identifiable {
    let space: DesktopSpace
    let name: String
    var preview: NSImage? = nil
    var id: String { space.id }
}

@MainActor
final class WindowPickerViewModel: ObservableObject {
    @Published private(set) var windows: [WindowCandidate] = []
    @Published private(set) var destinations: [WindowDestination] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsPermission = false
    @Published private(set) var canUndoArrangement = false
    private var readUndoArrangement: () -> Bool = { false }
    @Published var query = "" { didSet { reconcileWindowSelection() } }
    @Published var selectedWindowID: CGWindowID? {
        didSet { if oldValue != selectedWindowID { updateDestinations() } }
    }
    @Published var selectedDestinationID: String?
    @Published var checkedWindowIDs: Set<CGWindowID> = [] { didSet { updateDestinations() } }

    @Published var desktopFilter: Int? { didSet { reconcileWindowSelection() } }

    var selectedWindows: [WindowCandidate] {
        if !checkedWindowIDs.isEmpty { return filteredWindows.filter { checkedWindowIDs.contains($0.id) } }
        return selectedWindow.map { [$0] } ?? []
    }

    var batchRequest: (windows: [WindowSelection], destination: DesktopSpace)? {
        guard !isLoading, errorMessage == nil, !selectedWindows.isEmpty,
              let target = destinations.first(where: { $0.id == selectedDestinationID }) else { return nil }
        return (selectedWindows.map(\.selection), target.space)
    }

    func selectApplicationWindows() {
        guard let selectedWindow else { return }
        checkedWindowIDs = Set(filteredWindows.filter { $0.selection.processID == selectedWindow.selection.processID }.map(\.id))
    }

    private let readWindows: () async throws -> [WindowCandidate]
    private let readDestinations: (WindowSelection) -> [WindowDestination]
    private var generation = 0
    private var cancellables: Set<AnyCancellable> = []

    init(readWindows: @escaping () async throws -> [WindowCandidate],
         readDestinations: @escaping (WindowSelection) -> [WindowDestination]) {
        self.readWindows = readWindows
        self.readDestinations = readDestinations
    }

    convenience init(desktops: DesktopsViewModel) {
        self.init(readWindows: { try await desktops.windowsForMove() }, readDestinations: { selection in
            desktops.reload()
            return desktops.windowMoveDestinations(for: .success(selection)).map {
                WindowDestination(space: $0, name: desktops.name(for: $0), preview: desktops.thumbnail(for: $0))
            }
        })
        readUndoArrangement = { desktops.canUndoArrangement }
        desktops.changes.sink { [weak self] in self?.updateDestinations() }.store(in: &cancellables)
    }

    var filteredWindows: [WindowCandidate] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let windows = windows.filter { desktopFilter == nil || $0.selection.sourceSpaceID == desktopFilter }
        guard !text.isEmpty else { return windows }
        return windows.filter { $0.title.localizedStandardContains(text) || $0.appName.localizedStandardContains(text) }
    }

    var selectedWindow: WindowCandidate? { filteredWindows.first { $0.id == selectedWindowID } }

    /// A value snapshot: closing or activating the popup never recaptures focus.
    var moveRequest: (window: WindowSelection, destination: DesktopSpace)? {
        guard !isLoading, errorMessage == nil, let window = selectedWindow,
              let destination = destinations.first(where: { $0.id == selectedDestinationID }) else { return nil }
        return (window.selection, destination.space)
    }

    func load() async {
        guard !Task.isCancelled else { return }
        generation += 1
        let request = generation
        canUndoArrangement = readUndoArrangement()
        isLoading = true
        errorMessage = nil
        needsPermission = false
        checkedWindowIDs = []
        windows = []
        selectedWindowID = nil
        destinations = []
        selectedDestinationID = nil
        query = ""
        desktopFilter = nil
        defer { if request == generation { isLoading = false } }
        do {
            let fresh = try await readWindows()
            try Task.checkCancellation()
            guard request == generation else { return }
            windows = fresh
            reconcileWindowSelection()
        } catch is CancellationError {
            return
        } catch {
            guard request == generation else { return }
            needsPermission = (error as? WindowMoveError) == .needsPermission
            errorMessage = error.localizedDescription
        }
    }

    func stepDestination(_ offset: Int) {
        guard !destinations.isEmpty else { return }
        let index = destinations.firstIndex { $0.id == selectedDestinationID } ?? 0
        selectedDestinationID = destinations[min(max(index + offset, 0), destinations.count - 1)].id
    }

    func stepWindow(_ offset: Int) {
        let visible = filteredWindows
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedWindowID } ?? 0
        selectedWindowID = visible[min(max(index + offset, 0), visible.count - 1)].id
    }

    private func reconcileWindowSelection() {
        checkedWindowIDs.formIntersection(Set(filteredWindows.map(\.id)))
        if !filteredWindows.contains(where: { $0.id == selectedWindowID }) {
            selectedWindowID = filteredWindows.first?.id
        }
    }

    private func updateDestinations() {
        let selected = selectedWindows
        guard !selected.contains(where: \.isMinimized) else { destinations = []; selectedDestinationID = nil; return }
        destinations = selected.first.map { readDestinations($0.selection) } ?? []
        for window in selected.dropFirst() {
            let allowed = Set(readDestinations(window.selection).map(\.id))
            destinations.removeAll { !allowed.contains($0.id) }
        }
        if !destinations.contains(where: { $0.id == selectedDestinationID }) {
            selectedDestinationID = destinations.first?.id
        }
    }
}
