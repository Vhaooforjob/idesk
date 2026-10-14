import Combine
import CoreGraphics
import XCTest
@testable import iDesk

/// Screens in memory: applying a layout just changes the list.
@MainActor
final class FakeDisplayService: DisplayControlling {
    @Published var displays: [DisplayInfo]
    var applied: [DisplayLayout] = []
    var recovered = 0
    var failure: Error?
    var canTurnOff = true
    var menuBarDisplay: CGDirectDisplayID = 1

    init(_ displays: [DisplayInfo] = []) {
        self.displays = displays
    }

    var displaysPublisher: AnyPublisher<[DisplayInfo], Never> { $displays.eraseToAnyPublisher() }
    var currentLayout: DisplayLayout { DisplayLayout(enabled: Set(displays.filter(\.isEnabled).map(\.id))) }

    func apply(_ layout: DisplayLayout) throws {
        guard !layout.enabled.isEmpty else { throw DisplayError.noScreenLeft }
        if let failure { throw failure }
        applied.append(layout)
        displays = displays.map { display in
            var display = display
            display.isEnabled = layout.enabled.contains(display.id)
            return display
        }
    }

    func recoverAll() throws {
        recovered += 1
        displays = displays.map { display in
            var display = display
            display.isEnabled = true
            return display
        }
    }

    func refresh() {}
}

private let builtIn = DisplayInfo(id: 1, name: "Built-in", isBuiltin: true, isEnabled: true)
private let tv = DisplayInfo(id: 3, name: "TV", isBuiltin: false, isEnabled: true)
private let projector = DisplayInfo(id: 5, name: "Projector", isBuiltin: false, isEnabled: true)

private func off(_ display: DisplayInfo) -> DisplayInfo {
    var display = display
    display.isEnabled = false
    return display
}

final class DisplayArrangementTests: XCTestCase {
    func testThePrimaryScreenIsTheBuiltInOne() {
        XCTAssertEqual(DisplayArrangement.primary(of: [tv, builtIn], menuBarDisplay: 3), 1)
        XCTAssertEqual(DisplayArrangement.primary(of: [tv, projector], menuBarDisplay: 5), 5)
    }

    func testLayouts() {
        let all = [builtIn, tv, projector]
        XCTAssertEqual(DisplayArrangement.allOn.layout(for: all, primary: 1), DisplayLayout(enabled: [1, 3, 5]))
        XCTAssertEqual(DisplayArrangement.mainOnly.layout(for: all, primary: 1), DisplayLayout(enabled: [1]))
        XCTAssertEqual(DisplayArrangement.externalOnly(5).layout(for: all, primary: 1), DisplayLayout(enabled: [5]))
        XCTAssertNil(DisplayArrangement.externalOnly(1).layout(for: all, primary: 1), "the main screen is not external")
    }

    func testRecognisesTheCurrentArrangement() {
        XCTAssertEqual(DisplayArrangement.current(of: [builtIn, tv], primary: 1), .allOn)
        XCTAssertEqual(DisplayArrangement.current(of: [builtIn, off(tv)], primary: 1), .mainOnly)
        XCTAssertEqual(DisplayArrangement.current(of: [off(builtIn), tv], primary: 1), .externalOnly(3))
        XCTAssertEqual(DisplayArrangement.current(of: [builtIn, tv, off(projector)], primary: 1), .custom)
        XCTAssertEqual(DisplayArrangement.current(of: [builtIn], primary: 1), .allOn)
    }
}

@MainActor
final class DisplaysViewModelTests: XCTestCase {
    func testOffersOneExternalOnlyChoicePerExternalScreen() {
        let viewModel = DisplaysViewModel(service: FakeDisplayService([builtIn, tv, projector]), dialogs: FakeDialogs())
        XCTAssertEqual(viewModel.arrangements, [.allOn, .mainOnly, .externalOnly(3), .externalOnly(5)])
        XCTAssertEqual(viewModel.title(for: .externalOnly(5)), "Only Projector")
        XCTAssertEqual(viewModel.externals.map(\.name), ["TV", "Projector"])
    }

    func testNothingToOfferWhenScreensCannotBeTurnedOff() {
        let service = FakeDisplayService([builtIn, tv])
        service.canTurnOff = false
        XCTAssertEqual(DisplaysViewModel(service: service, dialogs: FakeDialogs()).arrangements, [])
    }

    func testKeptChangeStays() {
        let service = FakeDisplayService([builtIn, tv])
        let dialogs = FakeDialogs()
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        viewModel.choose(.externalOnly(3))
        XCTAssertEqual(dialogs.keepQuestions, 1)
        XCTAssertEqual(viewModel.arrangement, .externalOnly(3))
    }

    func testSwappingTheOnlyScreenAsksToo() {
        let service = FakeDisplayService([off(builtIn), tv, off(projector)])
        let dialogs = FakeDialogs()
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        viewModel.choose(.externalOnly(5))
        XCTAssertEqual(dialogs.keepQuestions, 1, "the TV went dark, maybe with the dialog on it")
    }

    func testUnconfirmedChangeUndoesItself() {
        let service = FakeDisplayService([builtIn, tv])
        let dialogs = FakeDialogs()
        dialogs.keepsDisplays = false
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        viewModel.choose(.mainOnly)
        XCTAssertEqual(service.applied, [DisplayLayout(enabled: [1]), DisplayLayout(enabled: [1, 3])])
        XCTAssertEqual(viewModel.arrangement, .allOn)
    }

    func testTurningScreensBackOnNeedsNoConfirmation() {
        let service = FakeDisplayService([builtIn, off(tv)])
        let dialogs = FakeDialogs()
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        XCTAssertTrue(viewModel.hasScreensOff)
        viewModel.choose(.allOn)
        XCTAssertEqual(dialogs.keepQuestions, 0)
        XCTAssertFalse(viewModel.hasScreensOff)
    }

    func testAFailedChangeGoesBackToTheSafeState() {
        let service = FakeDisplayService([builtIn, tv])
        service.failure = DisplayError.failed(.failure)
        let dialogs = FakeDialogs()
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        viewModel.choose(.mainOnly)
        XCTAssertEqual(service.recovered, 1)
        XCTAssertEqual(dialogs.errors, ["Could not change the screens"])
        XCTAssertEqual(viewModel.arrangement, .allOn)
    }

    func testTurnEverythingOnRecovers() {
        let service = FakeDisplayService([builtIn, off(tv)])
        let viewModel = DisplaysViewModel(service: service, dialogs: FakeDialogs())
        viewModel.turnEverythingOn()
        XCTAssertEqual(service.recovered, 1)
        XCTAssertEqual(viewModel.arrangement, .allOn)
    }

    func testTheLastScreenOnCannotBeToggled() {
        let viewModel = DisplaysViewModel(service: FakeDisplayService([builtIn, off(tv)]), dialogs: FakeDialogs())
        XCTAssertFalse(viewModel.canToggle(builtIn), "the only screen on")
        XCTAssertTrue(viewModel.canToggle(off(tv)), "a screen that is off can always come on")
        let both = DisplaysViewModel(service: FakeDisplayService([builtIn, tv]), dialogs: FakeDialogs())
        XCTAssertTrue(both.canToggle(builtIn))
    }

    func testTheLastScreenStaysOn() {
        let service = FakeDisplayService([builtIn, off(tv)])
        let dialogs = FakeDialogs()
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        viewModel.setEnabled(builtIn, false)
        XCTAssertEqual(service.applied, [])
        XCTAssertEqual(dialogs.errors, ["Could not change the screens"])
    }
}

/// Models hardware independently from the service cache. A disabled panel can
/// disappear from enumeration, and a detached ID rejects enable requests.
@MainActor
private final class FakeDisplaySystem: DisplaySystem {
    struct Change: Equatable {
        let ids: [CGDirectDisplayID]
        let enabled: Bool
    }
    var connected = [builtIn, tv]
    var uuids: [CGDirectDisplayID: String] = [1: "built-in", 3: "tv", 5: "projector"]
    var hideDisabled = true
    var failing: Set<CGDirectDisplayID> = []
    var delayed: Set<CGDirectDisplayID> = []
    var changes: [Change] = []
    var afterChange: (() -> Void)?
    var failAfterDisable = false
    var menuBarDisplay: CGDirectDisplayID = 1
    var canTurnOff = true

    func read() -> [DisplayInfo] { connected.filter { !hideDisabled || $0.isEnabled } }
    func identifier(for id: CGDirectDisplayID) -> String? { uuids[id] }
    func setEnabled(_ ids: [CGDirectDisplayID], _ enabled: Bool) throws {
        changes.append(Change(ids: ids, enabled: enabled))
        guard ids.allSatisfy({ id in connected.contains { $0.id == id } && !failing.contains(id) }) else {
            throw DisplayError.failed(.illegalArgument)
        }
        for index in connected.indices where ids.contains(connected[index].id) && !delayed.contains(connected[index].id) {
            connected[index].isEnabled = enabled
        }
        afterChange?()
        if !enabled && failAfterDisable { throw DisplayError.failed(.failure) }
    }
    var lit: Set<CGDirectDisplayID> { Set(connected.filter(\.isEnabled).map(\.id)) }
}

@MainActor
final class DisplayServiceTests: XCTestCase {
    func testWatchdogRecoversAnUnplugWithoutASystemNotification() async throws {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system)
        try service.apply(DisplayLayout(enabled: [3]))
        system.connected.removeAll { $0.id == 3 }
        let recovered = expectation(description: "Watchdog lights the built-in display")
        system.afterChange = {
            if system.lit == [1] { recovered.fulfill() }
        }
        await fulfillment(of: [recovered], timeout: 3)
        system.afterChange = nil
        XCTAssertEqual(system.lit, [1])
        try service.recoverAll()
    }

    func testUnplugFallsBackAndReconnectRestoresExternalOnlyRepeatedly() throws {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        try service.apply(DisplayLayout(enabled: [3]))
        XCTAssertEqual(system.lit, [3])
        for _ in 0..<3 {
            system.connected.removeAll { $0.id == 3 }
            service.refresh()
            XCTAssertEqual(system.lit, [1])
            XCTAssertEqual(service.currentLayout.enabled, [1])
            system.connected.append(tv)
            service.refresh()
            XCTAssertEqual(system.lit, [3])
            XCTAssertEqual(service.currentLayout.enabled, [3])
        }
    }

    func testSameMonitorWithNewDisplayIDIsRecognisedByUUID() throws {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        try service.apply(DisplayLayout(enabled: [3]))
        system.connected.removeAll { $0.id == 3 }
        service.refresh()
        system.uuids[7] = "tv"
        system.connected.append(DisplayInfo(id: 7, name: "TV", isBuiltin: false, isEnabled: true))
        service.refresh()
        XCTAssertEqual(system.lit, [7])
    }

    func testAnotherMonitorReusingTheOldIDDoesNotReplacePreference() throws {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        try service.apply(DisplayLayout(enabled: [3]))
        system.connected.removeAll { $0.id == 3 }
        service.refresh()
        system.uuids[3] = "other-monitor"
        system.connected.append(tv)
        service.refresh()
        XCTAssertEqual(system.lit, [1])
    }

    func testReconnectWaitsForExternalToBeActiveBeforeDisablingFallback() throws {
        let system = FakeDisplaySystem()
        system.hideDisabled = false
        let service = DisplayService(system: system, observeChanges: false)
        try service.apply(DisplayLayout(enabled: [3]))
        system.connected.removeAll { $0.id == 3 }
        service.refresh()
        system.connected.append(off(tv))
        system.delayed = [3]
        system.changes.removeAll()
        service.refresh()
        XCTAssertEqual(system.lit, [1])
        XCTAssertFalse(system.changes.contains { !$0.enabled })
        system.delayed.removeAll()
        service.refresh()
        XCTAssertEqual(system.lit, [3])
        XCTAssertEqual(system.changes.last, .init(ids: [1], enabled: false))
    }

    func testTransientFailureRetriesWithoutLosingPreference() throws {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        try service.apply(DisplayLayout(enabled: [3]))
        system.connected.removeAll { $0.id == 3 }
        system.failing = [1]
        service.refresh()
        XCTAssertTrue(system.lit.isEmpty)
        system.failing.removeAll()
        service.refresh()
        XCTAssertEqual(system.lit, [1])
        system.connected.append(tv)
        service.refresh()
        XCTAssertEqual(system.lit, [3])
    }

    func testRecoveryIsolatesDetachedIDsAndCancelsRestoration() throws {
        let system = FakeDisplaySystem()
        system.connected.append(projector)
        let service = DisplayService(system: system, observeChanges: false)
        try service.apply(DisplayLayout(enabled: [3]))
        system.connected.removeAll { $0.id != 1 }
        system.changes.removeAll()
        try service.recoverAll()
        XCTAssertEqual(system.lit, [1])
        XCTAssertEqual(system.changes.first, .init(ids: [1], enabled: true))
        XCTAssertFalse(service.displays.contains { $0.id == 5 })
        system.connected.append(tv)
        service.refresh()
        XCTAssertEqual(system.lit, [1, 3])
    }

    func testAllOnWhileUnpluggedCancelsRestorationEvenThoughLayoutIsUnchanged() throws {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        let dialogs = FakeDialogs()
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        viewModel.choose(.externalOnly(3))
        system.connected.removeAll { $0.id == 3 }
        service.refresh()
        viewModel.choose(.allOn)
        XCTAssertEqual(dialogs.keepQuestions, 1)
        system.connected.append(tv)
        service.refresh()
        XCTAssertEqual(system.lit, [1, 3])
    }

    func testRejectedChoiceDoesNotReturnOnReconnect() {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        let dialogs = FakeDialogs()
        dialogs.keepsDisplays = false
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        viewModel.choose(.externalOnly(3))
        XCTAssertEqual(system.lit, [1, 3])
        system.connected.removeAll { $0.id == 3 }
        service.refresh()
        system.connected.append(tv)
        service.refresh()
        XCTAssertEqual(system.lit, [1, 3])
    }

    func testDetachedLayoutCannotTurnOffLastWorkingScreen() {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        system.connected.removeAll { $0.id == 3 }
        XCTAssertThrowsError(try service.apply(DisplayLayout(enabled: [3])))
        XCTAssertEqual(system.lit, [1])
        XCTAssertTrue(system.changes.isEmpty)
    }

    func testMacOSReenabledScreenIsNotMaskedByTheTurnedOffCache() throws {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        try service.apply(DisplayLayout(enabled: [1]))
        system.connected = [builtIn, tv]
        service.refresh()
        XCTAssertEqual(service.currentLayout.enabled, [1, 3])
    }

    func testUnplugDuringDisableTransactionRecoversBeforeReturning() throws {
        let system = FakeDisplaySystem()
        let service = DisplayService(system: system, observeChanges: false)
        system.afterChange = {
            if system.changes.last?.enabled == false {
                system.connected.removeAll { $0.id == 3 }
                service.refresh() // A reentrant event must not nest configuration.
            }
        }
        try service.apply(DisplayLayout(enabled: [3]))
        XCTAssertEqual(system.lit, [1])
        system.afterChange = nil
        system.connected.append(tv)
        service.refresh()
        XCTAssertEqual(system.lit, [3])
    }

    func testFailedDisableStillKeepsRecoveryCandidates() {
        let system = FakeDisplaySystem()
        system.failAfterDisable = true
        let service = DisplayService(system: system, observeChanges: false)
        let dialogs = FakeDialogs()
        let viewModel = DisplaysViewModel(service: service, dialogs: dialogs)
        viewModel.choose(.externalOnly(3))
        XCTAssertEqual(system.lit, [1, 3])
        XCTAssertEqual(dialogs.errors.count, 1)
    }

    func testOneFailedRecoveryDoesNotCancelOtherScreenEnables() throws {
        let system = FakeDisplaySystem()
        system.hideDisabled = false
        system.connected.append(projector)
        let service = DisplayService(system: system, observeChanges: false)
        try service.apply(DisplayLayout(enabled: [3]))
        system.failing = [1]
        XCTAssertThrowsError(try service.recoverAll())
        XCTAssertEqual(system.lit, [3, 5])
        system.failing.removeAll()
        try service.recoverAll()
        XCTAssertEqual(system.lit, [1, 3, 5])
    }
}
