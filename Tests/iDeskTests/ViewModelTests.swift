import AppKit
import Combine
import XCTest
@testable import iDesk

/// Answers dialogs the way a test says.
@MainActor
final class FakeDialogs: DialogPresenting {
    var nameToGive: String?
    var askedNames: [String] = []
    var confirmsDelete = true
    var keepsDisplays = true
    var keepQuestions = 0
    var errors: [String] = []

    func askForName(of space: DesktopSpace, current: String) -> String? {
        askedNames.append(current)
        return nameToGive
    }

    func confirmAccessibility() -> Bool { false }
    func confirmShortcutSettings() -> Bool { false }
    func confirmLanguageRestart() -> Bool { false }
    func confirmDelete(desktopNamed name: String) -> Bool { confirmsDelete }

    func confirmKeepDisplays(seconds: Int) -> Bool {
        keepQuestions += 1
        return keepsDisplays
    }

    func showError(_ title: String, _ error: Error) { errors.append(title) }

    var opensMissionControl = false
    func offerMissionControl(_ title: String, _ error: Error, howTo: String) -> Bool {
        errors.append(title)
        return opensMissionControl
    }
}

/// Records what Mission Control was asked to do.
@MainActor
final class FakeDesktopManager: DesktopManaging {
    var removed: [Int] = []
    var added = 0
    var opened = 0
    var failure: Error?

    func openMissionControl() { opened += 1 }

    func removeDesktop(at position: Int, on display: CGDirectDisplayID?) async throws {
        if let failure { throw failure }
        removed.append(position)
    }

    func addDesktop(on display: CGDirectDisplayID?) async throws {
        if let failure { throw failure }
        added += 1
    }
}

@MainActor
final class ViewModelTests: XCTestCase {
    private var folder: URL!
    private var settingsStore: SettingsStore!
    private var dialogs: FakeDialogs!
    private var manager: FakeDesktopManager!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iDeskTests-\(UUID().uuidString)")
        settingsStore = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        dialogs = FakeDialogs()
        manager = FakeDesktopManager()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        cancellables.removeAll()
    }

    private static func space(_ number: Int, display: String = "Main", kind: DesktopSpace.Kind = .desktop,
                              current: Bool = false) -> DesktopSpace {
        DesktopSpace(id: "S\(number)", managedID: number, displayID: display, kind: kind, position: number - 1,
                     number: kind == .desktop ? number : nil, ownerName: kind == .fullScreen ? "Safari" : nil, isCurrent: current)
    }

    private func makeDesktops(_ spaces: [DesktopSpace]) -> DesktopsViewModel {
        let service = SpaceService(read: { spaces })
        service.reload()
        return DesktopsViewModel(
            spaceService: service,
            thumbnailStore: ThumbnailStore(folder: folder.appendingPathComponent("Thumbnails")),
            settingsStore: settingsStore,
            switcher: SpaceSwitcher(spaces: service),
            desktopManager: manager,
            dialogs: dialogs
        )
    }

    private func makeDisplays() -> DisplaysViewModel {
        DisplaysViewModel(service: FakeDisplayService(), dialogs: dialogs)
    }

    private func anyScreen() throws -> NSScreen {
        try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first, "Needs a display")
    }

    // MARK: DesktopsViewModel

    func testRenameSavesTheNameAndHighlightsTheCard() {
        let desktop = Self.space(2)
        let desktops = makeDesktops([Self.space(1, current: true), desktop])
        var highlighted: [String] = []
        desktops.highlights.sink { highlighted.append($0) }.store(in: &cancellables)

        dialogs.nameToGive = "  Work "
        desktops.rename(desktop)
        XCTAssertEqual(dialogs.askedNames, ["Desktop 2"])
        XCTAssertEqual(desktops.name(for: desktop), "Work")
        XCTAssertEqual(highlighted, ["S2"])

        dialogs.nameToGive = nil
        desktops.rename(desktop)
        XCTAssertEqual(desktops.name(for: desktop), "Work", "Cancel keeps the name")

        dialogs.nameToGive = ""
        desktops.rename(desktop)
        XCTAssertEqual(desktops.name(for: desktop), "Desktop 2")
        XCTAssertNil(settingsStore.value.names["S2"])
    }

    func testResetNameGoesBackToTheDefault() {
        let desktop = Self.space(1)
        let desktops = makeDesktops([desktop])
        settingsStore.value.names["S1"] = "Music"
        desktops.resetName(desktop)
        XCTAssertEqual(desktops.name(for: desktop), "Desktop 1")
    }

    func testSpacesAreGroupedByDisplay() {
        let desktops = makeDesktops([Self.space(1, display: "A"), Self.space(2, display: "A"), Self.space(3, display: "B")])
        XCTAssertEqual(desktops.spacesByDisplay.map(\.displayID), ["A", "B"])
        XCTAssertEqual(desktops.spacesByDisplay.map { $0.spaces.count }, [2, 1])
    }

    func testOnlyOtherDesktopsCanBeDeleted() {
        let current = Self.space(1, current: true)
        let other = Self.space(2)
        let fullScreen = Self.space(3, kind: .fullScreen)
        let lonely = Self.space(4, display: "B")
        let desktops = makeDesktops([current, other, fullScreen, lonely])
        XCTAssertFalse(desktops.canDelete(current), "the desktop you are on")
        XCTAssertTrue(desktops.canDelete(other))
        XCTAssertFalse(desktops.canDelete(fullScreen), "full screen apps leave full screen instead")
        XCTAssertFalse(desktops.canDelete(lonely), "the last desktop on a display")
    }

    func testDeleteAsksThenUsesMissionControlAndForgetsTheName() async {
        let other = Self.space(2)
        let desktops = makeDesktops([Self.space(1, current: true), other])
        desktops.hasAccessibility = { true }
        settingsStore.value.names["S2"] = "Old"

        dialogs.confirmsDelete = false
        await desktops.delete(other)
        XCTAssertEqual(manager.removed, [], "cancelled")

        dialogs.confirmsDelete = true
        await desktops.delete(other)
        XCTAssertEqual(manager.removed, [1], "its position on the display")
        XCTAssertNil(settingsStore.value.names["S2"])
    }

    func testDeleteFailureIsShown() async {
        let desktops = makeDesktops([Self.space(1, current: true), Self.space(2)])
        desktops.hasAccessibility = { true }
        manager.failure = MissionControlError.notOpened
        await desktops.delete(Self.space(2))
        XCTAssertEqual(dialogs.errors, ["Could not delete the desktop"])
        XCTAssertEqual(manager.opened, 0)

        dialogs.opensMissionControl = true
        await desktops.delete(Self.space(2))
        XCTAssertEqual(manager.opened, 1, "falls back to doing it by hand")
    }

    func testAddDesktop() async {
        let desktops = makeDesktops([Self.space(1, current: true)])
        desktops.hasAccessibility = { true }
        await desktops.addDesktop(onDisplay: "Main")
        XCTAssertEqual(manager.added, 1)
    }

    // MARK: DesktopLineViewModel

    func testLineHangsNamedDesktopsAndHidesFullScreenApps() throws {
        let screen = try anyScreen()
        settingsStore.value.names["S1"] = "Work"
        let line = DesktopLineViewModel(desktops: makeDesktops([Self.space(1, current: true), Self.space(2, kind: .fullScreen)]))
        line.prepare(for: screen)
        XCTAssertEqual(line.items.map(\.name), ["Work"])

        settingsStore.value.showsFullScreenSpaces = true
        line.prepare(for: screen)
        XCTAssertEqual(line.items.map(\.name), ["Work", "Safari"])
    }

    func testLineFollowsTheLookSettings() async {
        let line = DesktopLineViewModel(desktops: makeDesktops([Self.space(1)]))
        settingsStore.value.hangStyle = .fairyLights
        settingsStore.value.visibility = .always
        XCTAssertEqual(line.look.style, .fairyLights)
        XCTAssertEqual(line.visibility, .always)
    }

    func testLineCelebratesHighlightedDesktops() {
        let desktops = makeDesktops([Self.space(1)])
        let line = DesktopLineViewModel(desktops: desktops)
        desktops.highlights.send("S1")
        desktops.highlights.send("S1")
        XCTAssertEqual(line.celebration, .init(id: "S1", tick: 2))
    }

    func testToggleAsksTheWindow() {
        let line = DesktopLineViewModel(desktops: makeDesktops([Self.space(1)]))
        var requests = 0
        line.toggleRequests.sink { requests += 1 }.store(in: &cancellables)
        line.toggle()
        XCTAssertEqual(requests, 1)
    }

    func testPreviewLineOnlyPlaysEffects() {
        let preview = DesktopLineViewModel(preview: SettingsViewModel.sampleDesktops, settings: Just(AppSettings()).eraseToAnyPublisher())
        XCTAssertTrue(preview.isPreview)
        preview.select(SettingsViewModel.sampleDesktops[2].space)
        XCTAssertEqual(preview.celebration.id, "sample-2")
    }

    // MARK: NameBannerViewModel

    func testBannerShowsTheNameOfTheDesktopArrivedOn() {
        let desktop = Self.space(3)
        let desktops = makeDesktops([desktop])
        let banner = NameBannerViewModel(desktops: desktops)
        settingsStore.value.names["S3"] = "Design"

        desktops.arrivals.send(desktop)
        XCTAssertTrue(banner.isPresented)
        XCTAssertEqual(banner.name, "Design")
        XCTAssertEqual(banner.subtitle, "Desktop 3")
    }

    func testBannerStaysAwayWhenOffOrForFullScreenApps() {
        let desktops = makeDesktops([Self.space(1), Self.space(2, kind: .fullScreen)])
        let banner = NameBannerViewModel(desktops: desktops)
        desktops.arrivals.send(Self.space(2, kind: .fullScreen))
        XCTAssertFalse(banner.isPresented)
        settingsStore.value.banner = .none
        desktops.arrivals.send(Self.space(1))
        XCTAssertFalse(banner.isPresented)
    }

    // MARK: MenuBarViewModel

    func testMenuBarTitle() {
        let desktop = Self.space(2)
        var settings = AppSettings()
        XCTAssertEqual(MenuBarViewModel.title(for: desktop, settings: settings), "Desktop 2")
        settings.names["S2"] = "Work"
        XCTAssertEqual(MenuBarViewModel.title(for: desktop, settings: settings), "2 · Work")
        settings.menuBarTitle = .name
        XCTAssertEqual(MenuBarViewModel.title(for: desktop, settings: settings), "Work")
        settings.menuBarTitle = .icon
        XCTAssertEqual(MenuBarViewModel.title(for: desktop, settings: settings), "")
        XCTAssertEqual(MenuBarViewModel.title(for: nil, settings: settings), "")
    }

    func testMenuListsDesktopsPerDisplayAndChangesSettings() {
        let desktops = makeDesktops([Self.space(1, display: "A", current: true), Self.space(2, display: "B")])
        let menu = MenuBarViewModel(desktops: desktops, line: DesktopLineViewModel(desktops: desktops),
                                    displays: makeDisplays(), settingsStore: settingsStore, dialogs: dialogs)
        XCTAssertEqual(menu.sections.map(\.title), ["Display 1", "Display 2"])
        XCTAssertEqual(menu.sections.flatMap(\.entries).map(\.title), ["1  Desktop 1", "2  Desktop 2"])

        let styles = menu.choiceGroups[0]
        XCTAssertEqual(styles.choices.filter(\.isSelected).map(\.title), [HangStyle.clothesline.title])
        styles.choices[HangStyle.allCases.firstIndex(of: .rail)!].select()
        XCTAssertEqual(settingsStore.value.hangStyle, .rail)
    }

    // MARK: SettingsViewModel

    func testSettingsEditsGoToTheStoreAndBack() {
        let desktop = Self.space(1)
        let settings = SettingsViewModel(settingsStore: settingsStore, desktops: makeDesktops([desktop]), screens: makeDisplays())

        settings.settings.sway = .windy
        XCTAssertEqual(settingsStore.value.sway, .windy)

        settingsStore.value.particles = .snow
        XCTAssertEqual(settings.settings.particles, .snow)

        settings.setCustomName("Chill", for: desktop)
        XCTAssertEqual(settingsStore.value.names["S1"], "Chill")
        XCTAssertEqual(settings.customName(for: desktop), "Chill")
        settings.setCustomName("", for: desktop)
        XCTAssertNil(settingsStore.value.names["S1"])
    }

    func testSettingsGroupsDesktopsByDisplay() {
        let settings = SettingsViewModel(settingsStore: settingsStore, desktops: makeDesktops([Self.space(1)]), screens: makeDisplays())
        XCTAssertEqual(settings.desktopGroups.map(\.title), ["Desktops"])
        XCTAssertEqual(settings.desktopGroups.first?.rows.map(\.id), ["S1"])
    }
}
