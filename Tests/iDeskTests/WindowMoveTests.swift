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

    func testPickerListsOnlyWindowsOnCurrentRegularDesktopsWithoutDuplicates() async throws {
        let system = FakeWindowSystem()
        system.listedWindows = [42, 43, 44, 45, 46, 42].map {
            WindowListEntry(id: UInt32($0), processID: 123, appName: "App", title: "Window \($0)")
        }
        system.membershipsByWindow = [42: [1], 43: [2], 44: [1, 2], 45: [3], 46: []]
        let service = WindowMoveService(system: system, readSpaces: {
            [desktop(1, current: true), desktop(2), desktop(3, current: true, kind: .fullScreen)]
        })
        let windows = try await service.availableWindows()
        XCTAssertEqual(windows.map(\.id), [42])
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
    func availableWindows() async throws -> [WindowCandidate] { [] }
    var captured = WindowSelection(id: 42, processID: 123, sourceSpaceID: 1)
    var moved: [WindowSelection] = []
    var focused: [WindowSelection] = []
    var error: Error?
    var onMove: (() async -> Void)?
    func captureFocusedWindow() throws -> WindowSelection {
        if let error { throw error }
        return captured
    }
    func move(_ window: WindowSelection, to destination: DesktopSpace) async throws {
        if let error { throw error }
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

    func testMenuListsNamedDestinations() {
        settings.value.setName("Work", for: desktop(2))
        let menu = MenuBarViewModel(desktops: viewModel, line: DesktopLineViewModel(desktops: viewModel),
            displays: DisplaysViewModel(service: FakeDisplayService(), dialogs: dialogs),
            settingsStore: settings, dialogs: dialogs)
        menu.refresh()
        XCTAssertEqual(menu.moveWindowGroup.choices.map(\.title), ["2  Work"])
    }
}
