import AppKit
import Combine

/// The desktops and what can be done with them: their names, their
/// previews, switching and renaming. The line, the banner, the menu bar and
/// Settings all build on it.
@MainActor
final class DesktopsViewModel {
    /// A desktop the user just arrived on.
    let arrivals = PassthroughSubject<DesktopSpace, Never>()
    let journal = OperationJournal()
    private let metadataChanges = PassthroughSubject<Void, Never>()
    private(set) var cachedWindows: [WindowCandidate] = []
    private(set) var recentDesktopIDs: [String] = []
    private var geometryHistory: [[(WindowSelection, CGRect)]] = []
    var canUndoArrangement: Bool { !geometryHistory.isEmpty && !isMovingWindow }
    var showWindows: ((String) -> Void)?
    private var refreshingWindows = false

    func refreshWindowMetadata() async {
        guard !refreshingWindows else { return }
        refreshingWindows = true
        defer { refreshingWindows = false }
        cachedWindows = (try? await windowsForMove()) ?? []
        metadataChanges.send(())
    }

    func windowMetadata(for space: DesktopSpace) -> [WindowCandidate] {
        guard settings.workspace.showsWindowBadges, !settings.privateDesktopIDs.contains(space.id) else { return [] }
        return cachedWindows.filter { $0.selection.sourceSpaceID == space.managedID }
    }

    func goAndWait(to id: String) async throws {
        reload()
        guard let space = spaces.first(where: { $0.id == id }) else { throw WindowMoveError.invalidDestination }
        switch switcher.go(to: space) {
        case .alreadyThere: return
        case .switching: break
        case .needsPermission: throw WindowMoveError.needsPermission
        case .noShortcut: throw SwitchError.didNotArrive
        }
        for _ in 0..<60 {
            try Task.checkCancellation()
            reload()
            if spaces.contains(where: { $0.id == id && $0.isCurrent }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SwitchError.didNotArrive
    }

    var arrangementBounds: (String) -> CGRect? = { displayID in
        DesktopsViewModel.screen(for: displayID).map(WorkspaceSessionService.accessibilityBounds)
    }

    func arrange(_ selections: [WindowSelection], using arrangement: WindowArrangement) async {
        await arrange(selections, using: arrangement, startingPositions: [:])
    }

    private func arrange(_ selections: [WindowSelection], using arrangement: WindowArrangement,
                         startingPositions: [String: Int]) async {
        guard !isMovingWindow else { return }
        isMovingWindow = true
        defer { isMovingWindow = false }
        var undo: [(WindowSelection, CGRect)] = []
        var failures: [String] = []
        do {
            let live = try await windowMover.availableWindows()
            var positions = startingPositions
            for selection in selections {
                let retryPositions = positions
                do {
                    guard let window = live.first(where: { $0.selection == selection && !$0.isMinimized }), let original = window.frame,
                          let space = spaces.first(where: { $0.managedID == selection.sourceSpaceID }),
                          let bounds = arrangementBounds(space.displayID) else { throw WindowMoveError.staleWindow }
                    let index = positions[space.displayID, default: 0]
                    if arrangement == .grid && index >= 4 { throw WorkspaceFeatureError(message: String(localized: "Select at most four windows per display for a grid.")) }
                    positions[space.displayID] = index + 1
                    // Preserve the original even if an app accepts only part of a resize.
                    undo.append((selection, original))
                    try windowMover.setFrame(arrangement.frame(in: bounds, original: original, index: index), of: selection)
                    journal.record(arrangement.title, item: "Window #\(selection.id)")
                } catch { failures.append(error.localizedDescription); journal.record(arrangement.title, item: "Window #\(selection.id)", error: error, retry: { [weak self] in await self?.arrange([selection], using: arrangement, startingPositions: retryPositions) }) }
            }
        } catch { journal.record(arrangement.title, item: "Windows", error: error) }
        if !undo.isEmpty { geometryHistory.append(undo); if geometryHistory.count > 20 { geometryHistory.removeFirst() } }
        if !failures.isEmpty { dialogs.showError(String(localized: "Some windows could not be arranged"), WorkspaceFeatureError(message: failures.joined(separator: "\n"))) }
    }

    func undoArrangement() async {
        guard !isMovingWindow, let records = geometryHistory.popLast() else { return }
        isMovingWindow = true
        defer { isMovingWindow = false }
        var failed: [(WindowSelection, CGRect)] = []
        for (window, frame) in records.reversed() {
            do {
                let live = try await windowMover.availableWindows()
                guard live.contains(where: { $0.selection == window }) else { throw WindowMoveError.staleWindow }
                try windowMover.setFrame(frame, of: window)
                journal.record("Undo Arrangement", item: "Window #\(window.id)")
            } catch {
                if (error as? WindowMoveError) != .staleWindow { failed.append((window, frame)) }
                journal.record("Undo Arrangement", item: "Window #\(window.id)", error: error)
            }
        }
        if !failed.isEmpty { geometryHistory.append(Array(failed.reversed())) }
    }
    /// A desktop whose card should play the switch effect.
    let highlights = PassthroughSubject<String, Never>()
    /// Whether iDesk may drive Mission Control; replaced in tests.
    var hasAccessibility: () -> Bool = { PermissionService.canSwitchDesktops }

    private let spaceService: SpaceService
    private let thumbnailStore: ThumbnailStore
    private let settingsStore: SettingsStore
    private let switcher: SpaceSwitching
    private let windowMover: WindowMoving
    private(set) var isMovingWindow = false
    private(set) var moveHistory: [[WindowMoveRecord]] = []
    var canUndoMove: Bool { !moveHistory.isEmpty && !isMovingWindow }
    struct WindowMoveRecord {
        let original: WindowSelection
        let source: DesktopSpace
        let destination: DesktopSpace
    }
    private let desktopManager: DesktopManaging
    private let dialogs: DialogPresenting
    private var lastCurrent: [String: String] = [:]
    private(set) var previousSpaces: [String: String] = [:]
    private var previewWork: DispatchWorkItem?
    private var pendingPreviewSpaces: Set<String> = []

    /// How long to wait after a switch before taking the new desktop's
    /// picture, so the slide has finished.
    private static let settleDelay: TimeInterval = 0.9

    init(spaceService: SpaceService, thumbnailStore: ThumbnailStore, settingsStore: SettingsStore,
         switcher: SpaceSwitching, desktopManager: DesktopManaging, dialogs: DialogPresenting,
         windowMover: WindowMoving? = nil) {
        self.spaceService = spaceService
        self.thumbnailStore = thumbnailStore
        self.settingsStore = settingsStore
        self.switcher = switcher
        self.windowMover = windowMover ?? WindowMoveService()
        self.desktopManager = desktopManager
        self.dialogs = dialogs
    }

    func start() {
        spaceService.onActiveSpaceChange = { [weak self] in self?.activeSpaceChanged() }
        spaceService.start()
        rememberCurrent()

        // Capture on arrival and when opening the line; idle desktops do not
        // need recurring screenshots or JPEG writes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            for screen in NSScreen.screens { self?.refreshPreview(on: screen) }
        }
    }

    // MARK: Reading

    var spaces: [DesktopSpace] { spaceService.spaces }
    var settings: AppSettings { settingsStore.value }

    /// Fires after anything a desktop card shows has changed: the Spaces,
    /// a preview, or a setting.
    var changes: AnyPublisher<Void, Never> {
        Publishers.Merge3(
            spaceService.$spaces.map { _ in () },
            thumbnailStore.$images.map { _ in () },
            settingsStore.$value.map { _ in () }
        )
        // @Published fires before the value is stored; read it a moment later.
        .merge(with: metadataChanges)
        .receive(on: RunLoop.main)
        .eraseToAnyPublisher()
    }

    var settingsChanges: AnyPublisher<AppSettings, Never> {
        settingsStore.$value.removeDuplicates().eraseToAnyPublisher()
    }

    func reload() {
        spaceService.reload()
    }

    func spaces(on screen: NSScreen?) -> [DesktopSpace] {
        spaceService.spaces(on: screen)
    }

    func currentSpace(on screen: NSScreen?) -> DesktopSpace? {
        spaceService.currentSpace(on: screen)
    }

    func name(for space: DesktopSpace) -> String {
        settings.name(for: space)
    }

    func thumbnail(for space: DesktopSpace) -> NSImage? {
        settings.showsPreviews && !settings.privateDesktopIDs.contains(space.id) ? thumbnailStore.images[space.id] : nil
    }

    /// The Spaces grouped by display, in Mission Control's order.
    var spacesByDisplay: [(displayID: String, spaces: [DesktopSpace])] {
        var order: [String] = []
        for space in spaces where !order.contains(space.displayID) { order.append(space.displayID) }
        return order.map { display in (display, spaces.filter { $0.displayID == display }) }
    }

    /// The cards to hang for a screen's desktops.
    func hangingDesktops(on screen: NSScreen) -> [HangingDesktop] {
        let value = settings
        let aspect = screen.frame.width / max(screen.frame.height, 1)
        return spaces(on: screen)
            .filter { value.showsFullScreenSpaces || $0.kind == .desktop }
            .map { space in
                HangingDesktop(
                    space: space,
                    name: value.name(for: space),
                    thumbnail: value.showsPreviews ? thumbnail(for: space) : nil,
                    appearance: value.appearances[space.id] ?? DesktopAppearance(),
                    aspect: aspect,
                    windows: windowMetadata(for: space)
                )
            }
    }

    // MARK: Switching

    func go(to space: DesktopSpace) {
        switch switcher.go(to: space) {
        case .switching:
            break
        case .alreadyThere:
            highlights.send(space.id)
        case .needsPermission:
            requestSwitchingPermission()
        case .noShortcut:
            if dialogs.confirmShortcutSettings() { PermissionService.openKeyboardShortcutSettings() }
        }
    }

    /// The switcher pressed the shortcuts but never arrived.
    func switchFailed(to space: DesktopSpace) {
        dialogs.showError(String(localized: "Could not switch to “\(name(for: space))”"), SwitchError.didNotArrive)
    }

    func requestSwitchingPermission() {
        guard dialogs.confirmAccessibility() else { return }
        PermissionService.requestSwitchDesktops()
        PermissionService.openAccessibilitySettings()
    }

    private func activeSpaceChanged() {
        switcher.spaceDidChange()
        let arrived = spaces.filter { $0.isCurrent && lastCurrent[$0.displayID] != $0.id }
        for space in arrived {
            if let previous = lastCurrent[space.displayID] {
                recentDesktopIDs.removeAll { $0 == previous }; recentDesktopIDs.insert(previous, at: 0)
                recentDesktopIDs = Array(recentDesktopIDs.prefix(30))
            }
            if let previous = lastCurrent[space.displayID] { previousSpaces[space.displayID] = previous }
        }
        rememberCurrent()
        guard let space = arrived.first else { return }
        arrivals.send(space)
        highlights.send(space.id)
        if settings.playsSounds { NSSound(named: "Pop")?.play() }
        previewWork?.cancel()
        pendingPreviewSpaces.formUnion(arrived.map(\.id))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pending = self.pendingPreviewSpaces
            self.pendingPreviewSpaces.removeAll()
            for screen in NSScreen.screens {
                if let current = self.currentSpace(on: screen), pending.contains(current.id) {
                    self.refreshPreview(on: screen)
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func rememberCurrent() {
        lastCurrent = Dictionary(spaces.filter(\.isCurrent).map { ($0.displayID, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    func goToPreviousDesktop() {
        reload()
        guard let current = currentSpace(on: SpaceService.screenUnderPointer),
              let id = previousSpaces[current.displayID],
              let target = spaces.first(where: { $0.id == id && $0.displayID == current.displayID }) else { return }
        go(to: target)
    }

    // MARK: Moving windows

    func captureWindowForMove() -> Result<WindowSelection, Error> {
        Result { try windowMover.captureFocusedWindow() }
    }

    func windowsForMove() async throws -> [WindowCandidate] {
        let windows = try await windowMover.availableWindows()
        return windows.map { window in
            var item = window
            if let space = spaces.first(where: { $0.managedID == item.selection.sourceSpaceID }) { item.desktopName = name(for: space) }
            return item
        }
    }

    func windowMoveDestinations(for selection: Result<WindowSelection, Error>) -> [DesktopSpace] {
        if case let .success(window) = selection,
           let source = spaces.first(where: { $0.managedID == window.sourceSpaceID }) {
            return spaces.filter { $0.kind == .desktop && $0.displayID == source.displayID && $0.id != source.id }
        }
        // Keep the action discoverable without permission; selecting it explains
        // what is needed, instead of silently presenting a disabled control.
        return spaces.filter { $0.kind == .desktop && !$0.isCurrent }
    }

    func moveWindow(_ selection: Result<WindowSelection, Error>, to destination: DesktopSpace, follow: Bool = true) async {
        do { await moveWindows([try selection.get()], to: destination, follow: follow) }
        catch { dialogs.showError(String(localized: "Could not move the window"), error) }
    }

    func moveWindows(_ windows: [WindowSelection], to destination: DesktopSpace, follow: Bool = true) async {
        guard !isMovingWindow, !windows.isEmpty else { return }
        isMovingWindow = true
        defer { isMovingWindow = false }
        var moved: [WindowMoveRecord] = []
        var errors: [String] = []
        var seen = Set<CGWindowID>()
        for window in windows where seen.insert(window.id).inserted {
            do {
                try Task.checkCancellation()
                reload()
                guard let source = spaces.first(where: { $0.managedID == window.sourceSpaceID }) else { throw WindowMoveError.staleWindow }
                try await windowMover.move(window, to: destination)
                moved.append(WindowMoveRecord(original: window, source: source, destination: destination))
                journal.record("Move Window", item: "Window #\(window.id)")
            } catch {
                errors.append(error.localizedDescription)
                journal.record("Move Window", item: "Window #\(window.id)", error: error, retry: { [weak self] in
                    await self?.moveWindows([window], to: destination, follow: false)
                })
            }
        }
        if !moved.isEmpty {
            moveHistory.append(moved)
            if moveHistory.count > 20 { moveHistory.removeFirst() }
            highlights.send(destination.id)
            if follow, let window = moved.first?.original {
                do { try await switchAndFocus(window, on: destination) }
                catch { errors.append(error.localizedDescription) }
            }
        }
        if !errors.isEmpty {
            dialogs.showError(String(localized: "Could not move the window"), WorkspaceFeatureError(message: errors.joined(separator: "\n")))
        }
    }

    func undoLastMove() async {
        guard !isMovingWindow, let records = moveHistory.popLast() else { return }
        isMovingWindow = true
        defer { isMovingWindow = false }
        var failed: [WindowMoveRecord] = []
        var messages: [String] = []
        for record in records.reversed() {
            do {
                let current = WindowSelection(id: record.original.id, processID: record.original.processID,
                                              sourceSpaceID: record.destination.managedID)
                try await windowMover.move(current, to: record.source)
            } catch {
                if (error as? WindowMoveError) != .staleWindow && (error as? WindowMoveError) != .invalidDestination {
                    failed.append(record)
                }
                messages.append(error.localizedDescription)
            }
        }
        if !failed.isEmpty {
            moveHistory.append(Array(failed.reversed()))
        }
        if !messages.isEmpty {
            dialogs.showError(String(localized: "Some windows could not be restored"), WorkspaceFeatureError(message: messages.joined(separator: "\n")))
        }
        reload()
    }

    func activateWindowAndWait(_ window: WindowSelection) async throws {
        reload()
        let fresh = try await windowMover.availableWindows()
        guard fresh.contains(where: { $0.selection == window }),
              let target = spaces.first(where: { $0.managedID == window.sourceSpaceID }) else { throw WindowMoveError.staleWindow }
        try await switchAndFocus(window, on: target)
    }

    func activateWindow(_ window: WindowSelection) async {
        do { try await activateWindowAndWait(window) }
        catch { dialogs.showError(String(localized: "Could not open the window"), error) }
    }

    private func switchAndFocus(_ window: WindowSelection, on destination: DesktopSpace) async throws {
        reload()
        guard let target = spaces.first(where: { $0.id == destination.id }) else { throw WindowMoveError.followFailed }
        switch switcher.go(to: target) {
        case .alreadyThere, .switching: break
        case .needsPermission, .noShortcut: throw WindowMoveError.followFailed
        }
        for _ in 0..<50 {
            reload()
            if spaces.contains(where: { $0.id == target.id && $0.isCurrent }) {
                try windowMover.focus(window)
                highlights.send(target.id)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw WindowMoveError.followFailed
    }

    /// Automation shares the same operation lock, but does not alter manual undo history.
    func placeWindow(_ window: WindowSelection, on target: DesktopSpace, frame: CGRect? = nil) async throws {
        guard !isMovingWindow else { throw WorkspaceFeatureError(message: String(localized: "A window operation is already running. Try again.")) }
        isMovingWindow = true
        defer { isMovingWindow = false }
        var selected = window
        if window.sourceSpaceID != target.managedID {
            try await windowMover.move(window, to: target)
            selected = WindowSelection(id: window.id, processID: window.processID, sourceSpaceID: target.managedID)
        }
        if let frame { try windowMover.setFrame(frame, of: selected) }
    }

    // MARK: Naming

    func rename(_ space: DesktopSpace) {
        guard let name = dialogs.askForName(of: space, current: name(for: space)) else { return }
        settingsStore.value.setName(name, for: space)
        highlights.send(space.id)
    }

    func renameCurrent() {
        guard let space = currentSpace(on: SpaceService.screenUnderPointer) else { return }
        rename(space)
    }

    func resetName(_ space: DesktopSpace) {
        settingsStore.value.setName("", for: space)
    }

    // MARK: Adding and deleting

    /// Mission Control keeps at least one desktop per display, and the one
    /// you are on cannot be deleted from under you. Full screen apps leave
    /// full screen instead.
    func canDelete(_ space: DesktopSpace) -> Bool {
        space.kind == .desktop && !space.isCurrent
            && spaces.filter { $0.displayID == space.displayID && $0.kind == .desktop }.count > 1
    }

    /// Deletes a desktop after asking. Its windows move to another desktop.
    func delete(_ space: DesktopSpace) async {
        guard canDelete(space), dialogs.confirmDelete(desktopNamed: name(for: space)) else { return }
        guard hasAccessibility() else { return requestSwitchingPermission() }
        do {
            try await desktopManager.removeDesktop(at: space.position, on: Self.displayNumber(for: space.displayID))
            settingsStore.value.workspace.organization[space.id] = nil
            settingsStore.value.workspace.pinnedCommands.remove("desktop:" + space.id)
            settingsStore.value.names[space.id] = nil
            settingsStore.value.desktopHotkeys[space.id] = nil
            settingsStore.value.appearances[space.id] = nil
            settingsStore.value.privateDesktopIDs.remove(space.id)
            settingsStore.value.windowRules.removeAll { $0.desktopID == space.id }
            reload()
        } catch {
            let howTo = String(localized: "In Mission Control, point at “\(name(for: space))” at the top of the screen and click its ✕.")
            if dialogs.offerMissionControl(String(localized: "Could not delete the desktop"), error, howTo: howTo) {
                desktopManager.openMissionControl()
            }
        }
    }

    /// Adds a desktop at the end of a display's desktops.
    func addDesktop(onDisplay displayID: String?) async {
        guard hasAccessibility() else { return requestSwitchingPermission() }
        do {
            try await desktopManager.addDesktop(on: displayID.flatMap(Self.displayNumber(for:)))
            reload()
        } catch {
            let howTo = String(localized: "In Mission Control, click + at the top right of the screen.")
            if dialogs.offerMissionControl(String(localized: "Could not add a desktop"), error, howTo: howTo) {
                desktopManager.openMissionControl()
            }
        }
    }

    /// Adds a desktop on the display under the pointer.
    func addDesktopHere() async {
        await addDesktop(onDisplay: currentSpace(on: SpaceService.screenUnderPointer)?.displayID)
    }

    // MARK: Previews

    func previewDate(for space: DesktopSpace) -> Date? { settings.privateDesktopIDs.contains(space.id) ? nil : thumbnailStore.dates[space.id] }

    func clearPreviews() throws { try thumbnailStore.clear() }

    func refreshCurrentPreviews() {
        for screen in NSScreen.screens { refreshPreview(on: screen, force: true) }
    }

    func refreshPreview(on screen: NSScreen, force: Bool = false) {
        guard settings.showsPreviews, let space = currentSpace(on: screen), !settings.privateDesktopIDs.contains(space.id) else { return }
        thumbnailStore.capture(space, on: screen, force: force) { [weak self] in
            guard let self, self.settings.showsPreviews, !self.settings.privateDesktopIDs.contains(space.id) else { return false }
            self.reload()
            return self.currentSpace(on: screen)?.id == space.id
        }
    }

    // MARK: Screens

    static func screen(for displayID: String) -> NSScreen? {
        NSScreen.screens.first { SpaceService.displayIdentifier(for: $0) == displayID }
    }

    /// The CoreGraphics number of a Spaces display identifier; nil for
    /// "Main", when every display shares the same Spaces.
    static func displayNumber(for displayID: String) -> CGDirectDisplayID? {
        screen(for: displayID)?.displayID
    }
}

enum SwitchError: LocalizedError {
    case didNotArrive

    var errorDescription: String? {
        String(localized: "macOS did not change desktops. Check that the Mission Control shortcuts in System Settings → Keyboard → Keyboard Shortcuts are on, and that the desktop is on the screen you are using.")
    }
}
