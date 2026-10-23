import AppKit
import Combine
import XCTest
@testable import iDesk

private func desktop(_ id: Int, display: String = "A", current: Bool = false,
                     kind: DesktopSpace.Kind = .desktop) -> DesktopSpace {
    DesktopSpace(id: "S\(id)", managedID: id, displayID: display, kind: kind,
                 position: id - 1, number: kind == .desktop ? id : nil, ownerName: nil, isCurrent: current)
}

@MainActor
private final class FakeWindowSystem: WindowMoveSystem {
    var listedWindows: [WindowListEntry] = []
    var membershipsByWindow: [CGWindowID: [Int]] = [:]
    var memberships = [1]
    var closed = false
    var applyMove = true
    var moves: [(CGWindowID, Int)] = []
    var focusCount = 0
    func focusedWindow() throws -> (id: CGWindowID, processID: pid_t) { (42, 123) }
    func validate(_ window: WindowSelection) throws {
        if closed { throw WindowMoveError.staleWindow }
    }
    func windows() async throws -> [WindowListEntry] { listedWindows }
    func spaces(for window: CGWindowID) throws -> [Int] { membershipsByWindow[window] ?? memberships }
    func move(_ window: CGWindowID, to space: Int) throws {
        moves.append((window, space))
        if applyMove { memberships = [space] }
    }
    func focus(_ window: WindowSelection) throws { focusCount += 1 }
}

@MainActor
final class WindowMoveServiceTests: XCTestCase {
    private let selection = WindowSelection(id: 42, processID: 123, sourceSpaceID: 1)

    func testPickerListsWindowsAcrossRegularDesktopsWithoutDuplicates() async throws {
        let system = FakeWindowSystem()
        system.listedWindows = [42, 43, 44, 45, 46, 42].map {
            WindowListEntry(id: UInt32($0), processID: 123, appName: "App", title: "Window \($0)")
        }
        system.membershipsByWindow = [42: [1], 43: [2], 44: [1, 2], 45: [3], 46: []]
        let service = WindowMoveService(system: system, readSpaces: {
            [desktop(1, current: true), desktop(2), desktop(3, current: true, kind: .fullScreen)]
        })
        let windows = try await service.availableWindows()
        XCTAssertEqual(windows.map(\.id), [42, 43])
        XCTAssertEqual(windows.first?.selection, selection)
        XCTAssertEqual(windows.first?.title, "Window 42")
    }

    func testCapturesAndMovesOnlyTheSelectedWindow() async throws {
        let system = FakeWindowSystem()
        let service = WindowMoveService(system: system, readSpaces: { [desktop(1, current: true), desktop(2)] })
        XCTAssertEqual(try service.captureFocusedWindow(), selection)
        try await service.move(selection, to: desktop(2))
        XCTAssertEqual(system.moves.count, 1)
        XCTAssertEqual(system.moves.first?.0, 42)
        XCTAssertEqual(system.memberships, [2])
        XCTAssertEqual(system.focusCount, 0, "focus is separate, after the desktop switch")
    }

    func testRejectsPinnedAndFullscreenWindows() {
        let system = FakeWindowSystem()
        let service = WindowMoveService(system: system, readSpaces: { [desktop(1, current: true, kind: .fullScreen), desktop(2)] })
        XCTAssertThrowsError(try service.captureFocusedWindow())
        system.memberships = [1, 2]
        XCTAssertThrowsError(try service.captureFocusedWindow())
        system.memberships = []
        XCTAssertThrowsError(try service.captureFocusedWindow())
    }

    func testRejectsClosedWindowWithoutMovingAnythingElse() async {
        let system = FakeWindowSystem()
        system.closed = true
        let service = WindowMoveService(system: system, readSpaces: { [desktop(1), desktop(2)] })
        do {
            try await service.move(selection, to: desktop(2))
            XCTFail("Expected a stale window error")
        } catch {}
        XCTAssertTrue(system.moves.isEmpty)
    }

    func testRejectsWindowMovedWhileMenuWasOpen() async {
        let system = FakeWindowSystem()
        system.memberships = [3]
        let service = WindowMoveService(system: system, readSpaces: { [desktop(1), desktop(2), desktop(3)] })
        do {
            try await service.move(selection, to: desktop(2))
            XCTFail("Expected a stale window error")
        } catch {}
        XCTAssertTrue(system.moves.isEmpty)
    }

    func testRejectsMissingFullscreenSameAndOtherDisplayDestinations() async {
        let system = FakeWindowSystem()
        let service = WindowMoveService(system: system, readSpaces: {
            [desktop(1), desktop(2, kind: .fullScreen), desktop(3, display: "B")]
        })
        for target in [desktop(1), desktop(2), desktop(3, display: "B"), desktop(4)] {
            do {
                try await service.move(selection, to: target)
                XCTFail("Expected an invalid destination error for \(target.id)")
            } catch {}
        }
        XCTAssertTrue(system.moves.isEmpty)
    }

    func testSilentSystemFailureIsDetected() async {
        let system = FakeWindowSystem()
        system.applyMove = false
        let service = WindowMoveService(system: system, readSpaces: { [desktop(1), desktop(2)] })
        do {
            try await service.move(selection, to: desktop(2))
            XCTFail("A private API returning without moving is not success")
        } catch {
            XCTAssertEqual(error as? WindowMoveError, .refused)
        }
        XCTAssertEqual(system.focusCount, 0)
    }
}

@MainActor
private final class FakeWindowMover: WindowMoving {
    var listedWindows: [WindowCandidate] = []
    func availableWindows() async throws -> [WindowCandidate] { listedWindows }
    var captured = WindowSelection(id: 42, processID: 123, sourceSpaceID: 1)
    var moved: [WindowSelection] = []
    var focused: [WindowSelection] = []
    var error: Error?
    var onMove: (() async -> Void)?
    var rejectedIDs = Set<CGWindowID>()
    var rejection: WindowMoveError = .staleWindow
    var destinations: [Int] = []
    var frames: [CGRect] = []
    func setFrame(_ frame: CGRect, of window: WindowSelection) throws {
        frames.append(frame)
        if rejectedIDs.contains(window.id) { throw rejection }
    }
    func captureFocusedWindow() throws -> WindowSelection {
        if let error { throw error }
        return captured
    }
    func move(_ window: WindowSelection, to destination: DesktopSpace) async throws {
        if let error { throw error }
        if rejectedIDs.contains(window.id) { throw rejection }
        destinations.append(destination.managedID)
        moved.append(window)
        await onMove?()
    }
    func focus(_ window: WindowSelection) throws { focused.append(window) }
}

@MainActor
private final class FakeWindowSwitcher: SpaceSwitching {
    var visits: [String] = []
    var onGo: ((DesktopSpace) -> Void)?
    var outcome = SpaceSwitcher.Outcome.switching
    func go(to space: DesktopSpace) -> SpaceSwitcher.Outcome {
        visits.append(space.id)
        onGo?(space)
        return outcome
    }
    func spaceDidChange() {}
}

@MainActor
final class WindowMoveViewModelTests: XCTestCase {
    private var folder: URL!
    private var source = [DesktopSpace]()
    private var settings: SettingsStore!
    private var mover: FakeWindowMover!
    private var switcher: FakeWindowSwitcher!
    private var dialogs: FakeDialogs!
    private var viewModel: DesktopsViewModel!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iDesk-WindowMove-\(UUID())")
        source = [desktop(1, current: true), desktop(2), desktop(3, kind: .fullScreen), desktop(4, display: "B")]
        settings = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        mover = FakeWindowMover()
        switcher = FakeWindowSwitcher()
        dialogs = FakeDialogs()
        let spaces = SpaceService(read: { [unowned self] in self.source })
        switcher.onGo = { [unowned self] target in
            self.source = self.source.map { space in
                var copy = space
                if space.displayID == target.displayID { copy.isCurrent = space.id == target.id }
                return copy
            }
        }
        viewModel = DesktopsViewModel(spaceService: spaces,
            thumbnailStore: ThumbnailStore(folder: folder.appendingPathComponent("thumbs")),
            settingsStore: settings, switcher: switcher, desktopManager: FakeDesktopManager(),
            dialogs: dialogs, windowMover: mover)
        viewModel.reload()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    func testGridRetryKeepsFourthCellAndUsesCurrentScreenBounds() async throws {
        var bounds = CGRect(x: 0, y: 25, width: 1600, height: 900)
        viewModel.arrangementBounds = { _ in bounds }
        let original = CGRect(x: 100, y: 100, width: 600, height: 400)
        mover.listedWindows = (42...45).map {
            WindowCandidate(selection: WindowSelection(id: UInt32($0), processID: 123, sourceSpaceID: 1),
                            appName: "App", title: "Window", frame: original)
        }
        mover.rejectedIDs = [45]
        await viewModel.arrange(mover.listedWindows.map(\.selection), using: .grid)
        let failed = try XCTUnwrap(viewModel.journal.entries.first(where: { $0.error != nil }))
        XCTAssertEqual(mover.frames.last, WindowArrangement.grid.frame(in: bounds, original: original, index: 3))
        mover.rejectedIDs = []
        bounds.size.width = 2000
        await viewModel.journal.retry(failed)
        XCTAssertEqual(mover.frames.count, 5)
        XCTAssertEqual(mover.frames.last, WindowArrangement.grid.frame(in: bounds, original: original, index: 3))
        XCTAssertNil(viewModel.journal.entries.first?.error)
    }

    func testDestinationsExcludeSourceFullscreenAndOtherDisplays() {
        XCTAssertEqual(viewModel.windowMoveDestinations(for: viewModel.captureWindowForMove()).map(\.id), ["S2"])
    }

    func testMoveUsesCapturedWindowThenSwitchesAndFocusesIt() async {
        let selection = viewModel.captureWindowForMove()
        mover.captured = WindowSelection(id: 99, processID: 456, sourceSpaceID: 1)
        await viewModel.moveWindow(selection, to: desktop(2))
        XCTAssertEqual(mover.moved.map(\.id), [42])
        XCTAssertEqual(switcher.visits, ["S2"])
        XCTAssertEqual(mover.focused.map(\.id), [42])
        XCTAssertTrue(dialogs.errors.isEmpty)
    }

    func testMoveWithoutFollowingNeverSwitchesOrFocuses() async {
        switcher.outcome = .noShortcut
        await viewModel.moveWindow(viewModel.captureWindowForMove(), to: desktop(2), follow: false)
        XCTAssertEqual(mover.moved.map(\.id), [42])
        XCTAssertTrue(switcher.visits.isEmpty)
        XCTAssertTrue(mover.focused.isEmpty)
        XCTAssertTrue(dialogs.errors.isEmpty)
    }

    func testFailedMoveDoesNotSwitchOrFocus() async {
        let selection = viewModel.captureWindowForMove()
        mover.error = WindowMoveError.refused
        await viewModel.moveWindow(selection, to: desktop(2))
        XCTAssertTrue(switcher.visits.isEmpty)
        XCTAssertTrue(mover.focused.isEmpty)
        XCTAssertEqual(dialogs.errors, ["Could not move the window"])
    }

    func testMissingPermissionShowsErrorWithoutMoving() async {
        mover.error = WindowMoveError.needsPermission
        await viewModel.moveWindow(viewModel.captureWindowForMove(), to: desktop(2))
        XCTAssertTrue(mover.moved.isEmpty)
        XCTAssertTrue(switcher.visits.isEmpty)
        XCTAssertEqual(dialogs.errors, ["Could not move the window"])
    }

    func testUnavailableShortcutDoesNotFocusWrongDesktop() async {
        switcher.outcome = .noShortcut
        switcher.onGo = nil
        await viewModel.moveWindow(viewModel.captureWindowForMove(), to: desktop(2))
        XCTAssertEqual(mover.moved.count, 1)
        XCTAssertTrue(mover.focused.isEmpty)
        XCTAssertEqual(dialogs.errors, ["Could not move the window"])
    }

    func testConcurrentRequestsDoNotMoveTwoWindows() async {
        let selection = viewModel.captureWindowForMove()
        mover.onMove = { [unowned self] in
            await self.viewModel.moveWindow(selection, to: desktop(2))
        }
        await viewModel.moveWindow(selection, to: desktop(2))
        XCTAssertEqual(mover.moved.count, 1)
    }

    func testBatchMoveRecordsOnlySuccessfulWindowsAndUndoUsesDestinationMembership() async {
        let first = mover.captured
        let second = WindowSelection(id: 43, processID: 124, sourceSpaceID: 1)
        mover.rejectedIDs = [43]
        await viewModel.moveWindows([first, first, second], to: desktop(2), follow: false)
        XCTAssertEqual(mover.moved.map(\.id), [42])
        XCTAssertEqual(viewModel.moveHistory.last?.count, 1)
        XCTAssertTrue(viewModel.canUndoMove)
        await viewModel.undoLastMove()
        XCTAssertEqual(mover.moved.last?.sourceSpaceID, 2)
        XCTAssertEqual(mover.destinations, [2, 1])
        XCTAssertFalse(viewModel.canUndoMove)
        XCTAssertTrue(switcher.visits.isEmpty)
    }

    func testFailedUndoRetainsOnlyUnrestoredWindowsForRetry() async {
        let second = WindowSelection(id: 43, processID: 124, sourceSpaceID: 1)
        await viewModel.moveWindows([mover.captured, second], to: desktop(2), follow: false)
        mover.rejectedIDs = [43]
        mover.rejection = .refused
        await viewModel.undoLastMove()
        XCTAssertEqual(viewModel.moveHistory.last?.map { $0.original.id }, [43])
        mover.rejectedIDs = []
        await viewModel.undoLastMove()
        XCTAssertFalse(viewModel.canUndoMove)
        XCTAssertEqual(mover.moved.filter { $0.id == 42 }.count, 2)
    }

    func testFollowFailureStillAllowsUndoOfSuccessfulMove() async {
        switcher.outcome = .noShortcut
        switcher.onGo = nil
        await viewModel.moveWindows([mover.captured], to: desktop(2))
        XCTAssertTrue(viewModel.canUndoMove)
        await viewModel.undoLastMove()
        XCTAssertEqual(mover.destinations, [2, 1])
    }

    func testClosedWindowDoesNotBlockOlderUndoHistory() async {
        await viewModel.moveWindows([mover.captured], to: desktop(2), follow: false)
        mover.rejectedIDs = [42]
        await viewModel.undoLastMove()
        XCTAssertFalse(viewModel.canUndoMove)
        XCTAssertEqual(dialogs.errors.last, "Some windows could not be restored")
    }

    func testRulesMoveOnlyNewWindowsOnceAndPauseForSessionRestore() async {
        settings.value.windowRules = [WindowRule(bundleID: "app.editor", appName: "Editor", desktopID: "S2")]
        var suspended = false
        let rules = WindowRuleService(store: settings, desktops: viewModel, suspended: { suspended })
        rules.hasPermission = { true }
        let original = WindowCandidate(selection: mover.captured, appName: "Editor", title: "Existing", bundleID: "app.editor")
        mover.listedWindows = [original]
        await rules.scan()
        XCTAssertTrue(mover.moved.isEmpty, "Starting rules must not move pre-existing windows")
        let fresh = WindowCandidate(selection: WindowSelection(id: 43, processID: 123, sourceSpaceID: 1),
                                    appName: "Editor", title: "New", bundleID: "app.editor")
        mover.listedWindows.append(fresh)
        await rules.scan()
        await rules.scan()
        XCTAssertEqual(mover.moved.map(\.id), [43], "Manual movement afterward must not trigger the rule again")
        suspended = true
        mover.listedWindows.append(WindowCandidate(selection: WindowSelection(id: 44, processID: 123, sourceSpaceID: 1),
                                                   appName: "Editor", title: "Session", bundleID: "app.editor"))
        await rules.scan()
        suspended = false
        await rules.scan()
        XCTAssertEqual(mover.moved.map(\.id), [43], "Session-created windows become the new baseline")
        XCTAssertTrue(viewModel.moveHistory.isEmpty)
    }

    func testSessionCaptureAndRestoreUsesDesktopAndFrameWithoutMovingOtherWindows() async throws {
        mover.listedWindows = [WindowCandidate(selection: mover.captured, appName: "Editor", title: "Document", bundleID: "app.editor")]
        let sessions = WorkspaceSessionService(desktops: viewModel)
        let captured = try await sessions.capture(launchItems: [])
        XCTAssertEqual(captured.windows.map(\.desktopID), ["S1"])
        let frame = CGRect(x: 10, y: 20, width: 500, height: 400)
        let session = WorkspaceSession(windows: [.init(bundleID: "app.editor", title: "Document", desktopID: "S2", frame: frame)])
        let errors = await sessions.restore(session)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(mover.frames, [frame])
        XCTAssertEqual(mover.destinations, [2])
        XCTAssertTrue(switcher.visits.isEmpty)
        XCTAssertTrue(viewModel.moveHistory.isEmpty)
        let missing = WorkspaceSession(windows: [.init(bundleID: "app.editor", title: "Document", desktopID: "missing")])
        let failed = await sessions.restore(missing)
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(mover.destinations, [2])
    }

    func testSessionRetryContainsOnlyFailuresAndUsesExplicitAmbiguousSelection() async {
        mover.listedWindows = [
            WindowCandidate(selection: mover.captured, appName: "Editor", title: "Same", bundleID: "app.editor"),
            WindowCandidate(selection: WindowSelection(id: 43, processID: 123, sourceSpaceID: 1), appName: "Editor", title: "Same", bundleID: "app.editor")]
        let sessions = WorkspaceSessionService(desktops: viewModel)
        let first = SavedWindowPlacement(bundleID: "app.editor", title: "Same", desktopID: "S2")
        let second = SavedWindowPlacement(bundleID: "app.editor", title: "Same", desktopID: "S2")
        sessions.selections[first.id] = mover.listedWindows[0].selection
        sessions.selections[second.id] = mover.listedWindows[1].selection
        mover.rejectedIDs = [43]
        let errors = await sessions.restore(WorkspaceSession(windows: [first, second]))
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(sessions.failedSession.windows.map(\.id), [second.id])
        XCTAssertEqual(mover.moved.map(\.id), [42])
        mover.rejectedIDs = []
        let remaining = sessions.failedSession
        let retryErrors = await sessions.restore(remaining)
        XCTAssertTrue(retryErrors.isEmpty)
        XCTAssertEqual(mover.moved.map(\.id), [42, 43])
    }

    func testFailedSessionRetryNeverReusesAnAlreadyRestoredWindow() async {
        let sessions = WorkspaceSessionService(desktops: viewModel, matchAttempts: 1)
        mover.listedWindows = [WindowCandidate(selection: mover.captured, appName: "Editor", title: "First", bundleID: "app.editor")]
        let session = WorkspaceSession(windows: [
            .init(bundleID: "app.editor", title: "First", desktopID: "S2"),
            .init(bundleID: "app.editor", title: "Missing", desktopID: "S2")])
        let firstErrors = await sessions.restore(session)
        XCTAssertEqual(firstErrors.count, 1)
        let remaining = sessions.failedSession
        let retryErrors = await sessions.restore(remaining, retrying: true)
        XCTAssertEqual(retryErrors.count, 1)
        XCTAssertEqual(mover.moved.map(\.id), [42])
    }

    func testPrivateDesktopSuppressesWindowBadgesAndFailedMovesAreRetryable() async {
        mover.listedWindows = [WindowCandidate(selection: mover.captured, appName: "Editor", title: "Private Document")]
        await viewModel.refreshWindowMetadata()
        XCTAssertEqual(viewModel.windowMetadata(for: desktop(1)).count, 1)
        settings.value.privateDesktopIDs = ["S1"]
        XCTAssertTrue(viewModel.windowMetadata(for: desktop(1)).isEmpty)
        mover.rejectedIDs = [42]
        await viewModel.moveWindows([mover.captured], to: desktop(2), follow: false)
        let failed = viewModel.journal.entries[0]
        XCTAssertNotNil(failed.retry)
        mover.rejectedIDs = []
        await viewModel.journal.retry(failed)
        XCTAssertEqual(mover.moved.map(\.id), [42])
        XCTAssertTrue(viewModel.canUndoMove)
    }

    func testPresetRepairChangesOnlyFailedItemsAndDuplicateUsesIndependentIDs() async {
        let sessions = WorkspaceSessionService(desktops: viewModel)
        let presets = PresetsViewModel(store: settings, displays: DisplaysViewModel(service: FakeDisplayService(), dialogs: dialogs), sessions: sessions)
        mover.listedWindows = [WindowCandidate(selection: mover.captured, appName: "Editor", title: "Document", bundleID: "app.editor")]
        var preset = WorkspacePreset(name: "Work", settings: settings.value)
        preset.session = WorkspaceSession(windows: [.init(bundleID: "app.editor", title: "Document", desktopID: "missing")])
        settings.value.presets = [preset]
        do { try await presets.applyAndWait(preset); XCTFail("Missing desktop must fail") } catch {}
        XCTAssertFalse(presets.isApplying)
        XCTAssertEqual(presets.failedSession.windows.count, 1)
        preset.session?.windows[0].desktopID = "S2"
        presets.update(preset)
        XCTAssertEqual(presets.failedSession.windows[0].desktopID, "S2")
        await presets.retryFailed()
        XCTAssertTrue(presets.failedSession.windows.isEmpty)
        XCTAssertEqual(mover.moved.map(\.id), [42])
        presets.duplicate(preset)
        XCTAssertNotEqual(presets.presets[0].id, presets.presets[1].id)
        XCTAssertNotEqual(presets.presets[0].session?.windows[0].id, presets.presets[1].session?.windows[0].id)
    }

    func testMenuListsNamedDestinations() {
        settings.value.setName("Work", for: desktop(2))
        let menu = MenuBarViewModel(desktops: viewModel, line: DesktopLineViewModel(desktops: viewModel),
            displays: DisplaysViewModel(service: FakeDisplayService(), dialogs: dialogs),
            settingsStore: settings, dialogs: dialogs)
        menu.refresh()
        XCTAssertEqual(menu.moveWindowGroup.choices.map(\.title), ["2  Work"])
    }
}
