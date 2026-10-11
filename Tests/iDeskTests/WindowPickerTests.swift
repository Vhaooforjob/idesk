import AppKit
import XCTest
@testable import iDesk

private func candidate(_ id: CGWindowID, app: String = "Safari", title: String = "Research", source: Int = 1) -> WindowCandidate {
    WindowCandidate(selection: WindowSelection(id: id, processID: 123, sourceSpaceID: source), appName: app, title: title)
}

private func destination(_ id: Int) -> WindowDestination {
    WindowDestination(space: DesktopSpace(id: "S\(id)", managedID: id, displayID: "A", kind: .desktop,
        position: id - 1, number: id, ownerName: nil, isCurrent: false), name: "Work \(id)")
}

@MainActor
final class WindowPickerTests: XCTestCase {
    func testOpensWithFirstWindowAndDestinationSelected() async {
        let model = WindowPickerViewModel(readWindows: { [candidate(42), candidate(43)] },
                                          readDestinations: { _ in [destination(2), destination(3)] })
        await model.load()
        XCTAssertEqual(model.selectedWindowID, 42)
        XCTAssertEqual(model.moveRequest?.window.id, 42)
        XCTAssertEqual(model.moveRequest?.destination.id, "S2")
        XCTAssertFalse(model.isLoading)
    }

    func testSearchMatchesAppAndTitleAndCannotMoveHiddenSelection() async {
        let model = WindowPickerViewModel(readWindows: {
            [candidate(42), candidate(43, app: "Terminal", title: "Build logs")]
        }, readDestinations: { _ in [destination(2)] })
        await model.load()
        model.query = " terminal "
        XCTAssertEqual(model.filteredWindows.map(\.id), [43])
        XCTAssertEqual(model.moveRequest?.window.id, 43)
        model.query = "RESEARCH"
        XCTAssertEqual(model.moveRequest?.window.id, 42)
        model.query = "nothing matches"
        XCTAssertNil(model.selectedWindowID)
        XCTAssertNil(model.moveRequest)
        XCTAssertTrue(model.destinations.isEmpty)
        model.query = ""
        XCTAssertEqual(model.moveRequest?.window.id, 42)
    }

    func testSelectingAnotherWindowReplacesInvalidDestination() async {
        let model = WindowPickerViewModel(readWindows: { [candidate(42), candidate(43, source: 2)] },
            readDestinations: { $0.sourceSpaceID == 1 ? [destination(2)] : [destination(1), destination(3)] })
        await model.load()
        model.selectedWindowID = 43
        XCTAssertEqual(model.moveRequest?.window.sourceSpaceID, 2)
        XCTAssertEqual(model.selectedDestinationID, "S1")
        model.selectedDestinationID = "S3"
        XCTAssertEqual(model.moveRequest?.destination.id, "S3")
    }

    func testEmptyWindowsOrNoDestinationCannotSubmit() async {
        let empty = WindowPickerViewModel(readWindows: { [] }, readDestinations: { _ in [destination(2)] })
        await empty.load()
        XCTAssertNil(empty.moveRequest)
        let singleDesktop = WindowPickerViewModel(readWindows: { [candidate(42)] }, readDestinations: { _ in [] })
        await singleDesktop.load()
        XCTAssertNil(singleDesktop.moveRequest)
        singleDesktop.selectedDestinationID = "missing"
        XCTAssertNil(singleDesktop.moveRequest)
    }

    func testPermissionErrorShowsSettingsAction() async {
        let model = WindowPickerViewModel(readWindows: { throw WindowMoveError.needsPermission }, readDestinations: { _ in [] })
        await model.load()
        XCTAssertTrue(model.needsPermission)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.moveRequest)
        XCTAssertFalse(model.isLoading)
    }

    func testRefreshClearsStaleWindowAndRecoversFromError() async {
        var shouldFail = true
        var windows = [candidate(42)]
        let model = WindowPickerViewModel(readWindows: {
            if shouldFail { throw WindowMoveError.needsPermission }
            return windows
        }, readDestinations: { _ in [destination(2)] })
        await model.load()
        shouldFail = false
        await model.load()
        XCTAssertFalse(model.needsPermission)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.moveRequest?.window.id, 42)
        windows = [candidate(99)]
        await model.load()
        XCTAssertEqual(model.moveRequest?.window.id, 99)
    }

    func testArrowNavigationStopsAtEnds() async {
        let model = WindowPickerViewModel(readWindows: { [candidate(42), candidate(43)] }, readDestinations: { _ in [destination(2)] })
        await model.load()
        model.stepWindow(-1)
        XCTAssertEqual(model.selectedWindowID, 42)
        model.stepWindow(1)
        model.stepWindow(1)
        XCTAssertEqual(model.selectedWindowID, 43)
        model.stepWindow(-1)
        XCTAssertEqual(model.selectedWindowID, 42)
    }

    func testOlderLoadCannotOverwriteReopenedPicker() async {
        var pending: [CheckedContinuation<[WindowCandidate], Never>] = []
        let firstStarted = expectation(description: "first load")
        let secondStarted = expectation(description: "second load")
        let model = WindowPickerViewModel(readWindows: {
            await withCheckedContinuation { continuation in
                pending.append(continuation)
                if pending.count == 1 { firstStarted.fulfill() } else { secondStarted.fulfill() }
            }
        }, readDestinations: { _ in [destination(2)] })
        let first = Task { await model.load() }
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertTrue(model.isLoading)
        XCTAssertNil(model.moveRequest)
        let second = Task { await model.load() }
        await fulfillment(of: [secondStarted], timeout: 2)
        pending[1].resume(returning: [candidate(99)])
        await second.value
        pending[0].resume(returning: [candidate(42)])
        await first.value
        XCTAssertEqual(model.moveRequest?.window.id, 99)
    }

    func testClosingDuringLoadDoesNotPublishResults() async {
        var pending: CheckedContinuation<[WindowCandidate], Never>?
        let started = expectation(description: "load")
        let model = WindowPickerViewModel(readWindows: {
            await withCheckedContinuation { pending = $0; started.fulfill() }
        }, readDestinations: { _ in [destination(2)] })
        let task = Task { await model.load() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        pending?.resume(returning: [candidate(42)])
        await task.value
        XCTAssertTrue(model.windows.isEmpty)
        XCTAssertNil(model.moveRequest)
    }

    func testPickerShortcutSurvivesSettingsRoundTripAndDefaultsForOldSettings() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.moveWindowHotkey, "⌃⌥M")
        var settings = old
        settings.moveWindowHotkey = "⌃⇧P"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.moveWindowHotkey, "⌃⇧P")
        XCTAssertEqual(HotkeyService.parse(old.moveWindowHotkey)?.keyCode, 46)
    }

    func testShortcutParserRequiresExactlyOneKey() {
        XCTAssertNotNil(HotkeyService.parse("ctrl+option+M"))
        XCTAssertEqual(HotkeyService.parse("ctrl+option+M")?.modifiers, HotkeyService.parse("⌃⌥M")?.modifiers)
        XCTAssertNil(HotkeyService.parse("ctrl+M+D"))
        XCTAssertNil(HotkeyService.parse("ctrl+typo+M"))
        XCTAssertNil(HotkeyService.parse("M"))
        XCTAssertNil(HotkeyService.parse("⌃⌥"))
    }
}
