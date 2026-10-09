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
