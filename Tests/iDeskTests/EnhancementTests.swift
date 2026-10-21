import AppKit
import Combine
import XCTest
@testable import iDesk

private func space(_ id: Int, display: String = "A", current: Bool = false) -> DesktopSpace {
    DesktopSpace(id: "S\(id)", managedID: id, displayID: display, kind: .desktop,
                 position: id - 1, number: id, ownerName: nil, isCurrent: current)
}

@MainActor
final class EnhancementTests: XCTestCase {
    private var folder: URL!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iDesk-Enhancements-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    func testSearchMatchesVietnameseNameNumberAndDisplayAndRejectsRemovedSelection() {
        var entries = [
            DesktopSearchViewModel.Entry(space: space(1, current: true), name: "Lập trình", displayName: "Display 1"),
            DesktopSearchViewModel.Entry(space: space(2), name: "Meeting", displayName: "Display 2")
        ]
        let model = DesktopSearchViewModel(read: { entries })
        model.open()
        XCTAssertEqual(model.selection?.id, "S2")
        model.query = " lap trinh "
        XCTAssertEqual(model.filtered.map(\.id), ["S1"])
        XCTAssertEqual(model.selection?.id, "S1")
        model.query = "meeting 2"
        XCTAssertEqual(model.selection?.id, "S2")
        entries.removeLast()
        model.refresh()
        XCTAssertNil(model.selection)
        model.query = "absent"
        model.step(1)
        XCTAssertNil(model.selection)
        model.query = ""
        XCTAssertEqual(model.selection?.id, "S1")
    }

    func testSearchNavigationClampsAndReopeningResetsQuery() {
        let model = DesktopSearchViewModel(read: {
            (1...3).map { .init(space: space($0), name: "Work \($0)", displayName: "Display 1") }
        })
        model.open()
        model.step(-10)
        XCTAssertEqual(model.selection?.id, "S1")
        model.step(10)
        XCTAssertEqual(model.selection?.id, "S3")
        model.query = "2"
        XCTAssertEqual(model.selection?.id, "S2")
        model.open()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selection?.id, "S1")
    }

    func testShortcutConflictsIncludeAliasesAndBothActionsAreRejected() {
        let errors = HotkeyService.validationErrors([
            .toggleLine: "⌃⌥D", .renameCurrent: "ctrl+option+d",
            .moveWindow: "bad key", .searchDesktops: "", .previousDesktop: "⌃⌥P"
        ])
        XCTAssertEqual(Set(errors.keys), [.toggleLine, .renameCurrent, .moveWindow])
        XCTAssertEqual(errors[.toggleLine], errors[.renameCurrent])
        XCTAssertTrue(HotkeyService.validationErrors(HotkeyService.shortcuts(in: AppSettings())).isEmpty)
        XCTAssertNil(HotkeyService.parse("⇧A"), "A global shortcut must not intercept ordinary uppercase typing.")
    }

    func testRecorderAcceptsCancelsClearsAndResumesShortcuts() throws {
        let button = RecorderButton()
        button.value = "⌃⌥D"
        var recorded: [String] = []
        var recordingStates: [Bool] = []
        let observer = NotificationCenter.default.publisher(for: HotkeyService.recordingChanged)
            .sink { recordingStates.append($0.object as? Bool ?? false) }
        defer { button.end(); observer.cancel() }
        button.changed = { recorded.append($0) }
        func event(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
        }
        button.begin()
        button.record(try event(0, .shift))
        XCTAssertTrue(button.isRecording)
        XCTAssertTrue(recorded.isEmpty)
        button.record(try event(1, [.control, .option]))
        XCTAssertEqual(recorded, ["⌃⌥S"])
        XCTAssertFalse(button.isRecording)
        button.begin()
        button.record(try event(53))
        XCTAssertEqual(button.value, "⌃⌥S")
        XCTAssertEqual(recorded.count, 1)
        button.begin()
        button.record(try event(51))
        XCTAssertEqual(recorded, ["⌃⌥S", ""])
        XCTAssertEqual(recordingStates, [true, false, true, false, true, false])
        button.begin()
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nil)
        XCTAssertFalse(button.isRecording)
        XCTAssertEqual(recordingStates.last, false)
    }

    func testPreviousDesktopTracksConfirmedArrivalsAndIgnoresDeletedDesktop() {
        var source = [space(1, current: true), space(2), space(3)]
        let service = SpaceService(read: { source })
        let switcher = HistorySwitcher()
        let store = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        store.value.showsPreviews = false
        let desktops = DesktopsViewModel(spaceService: service,
            thumbnailStore: ThumbnailStore(folder: folder), settingsStore: store, switcher: switcher,
            desktopManager: FakeDesktopManager(), dialogs: FakeDialogs())
        desktops.start()
        desktops.goToPreviousDesktop()
        XCTAssertTrue(switcher.visits.isEmpty)
        source = [space(1), space(2, current: true), space(3)]
        service.reload()
        service.onActiveSpaceChange?()
        desktops.goToPreviousDesktop()
        XCTAssertEqual(switcher.visits, ["S1"])
        // A request alone must not change the history; only a confirmed arrival does.
        XCTAssertEqual(desktops.previousSpaces["A"], "S1")
        source = [space(1, current: true), space(2), space(3)]
        service.reload()
        service.onActiveSpaceChange?()
        desktops.goToPreviousDesktop()
        XCTAssertEqual(switcher.visits, ["S1", "S2"])
        source = [space(1, current: true), space(3)]
        service.reload()
        desktops.goToPreviousDesktop()
        XCTAssertEqual(switcher.visits, ["S1", "S2"])
    }

    func testOldSettingsMigrateAndNewPreferencesRoundTrip() throws {
        var settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"names":{"S1":"Work"}}"#.utf8))
        XCTAssertTrue(settings.storesPreviewsOnDisk)
        XCTAssertTrue(settings.followMovedWindow)
        XCTAssertEqual(settings.searchDesktopsHotkey, "⌃⌥S")
        XCTAssertEqual(settings.names["S1"], "Work")
        settings.appearances["S1"] = DesktopAppearance(color: .purple, symbol: "book")
        settings.storesPreviewsOnDisk = false
        settings.followMovedWindow = false
        settings.presets = [WorkspacePreset(name: "Focus", settings: settings, screens: .mainOnly)]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testPresetRestoresAppearanceWithoutOverwritingNamesShortcutsOrStorage() {
        let store = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        let displays = DisplaysViewModel(service: FakeDisplayService(), dialogs: FakeDialogs())
        let model = PresetsViewModel(store: store, displays: displays)
        store.value.visibility = .hidden
        store.value.sway = .still
        model.save(name: " Focus ", screens: .unchanged, externalID: nil)
        XCTAssertEqual(model.presets.first?.name, "Focus")
        store.value.visibility = .always
        store.value.names["S1"] = "New name"
        store.value.searchDesktopsHotkey = "⌃⌥F"
        store.value.storesPreviewsOnDisk = false
        model.apply(model.presets[0])
        XCTAssertEqual(store.value.visibility, .hidden)
        XCTAssertEqual(store.value.names["S1"], "New name")
        XCTAssertEqual(store.value.searchDesktopsHotkey, "⌃⌥F")
        XCTAssertFalse(store.value.storesPreviewsOnDisk)
        model.remove(model.presets[0])
        XCTAssertTrue(store.value.presets.isEmpty)
    }

    func testCancelledPresetRestoresDisplaysAndKeepsAppearance() {
        let service = FakeDisplayService([
            DisplayInfo(id: 1, name: "Main", isBuiltin: true, isEnabled: true),
            DisplayInfo(id: 2, name: "External", isBuiltin: false, isEnabled: true)
        ])
        let dialogs = FakeDialogs()
        dialogs.keepsDisplays = false
        let store = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        let model = PresetsViewModel(store: store, displays: DisplaysViewModel(service: service, dialogs: dialogs))
        var settings = AppSettings()
        settings.visibility = .hidden
        let preset = WorkspacePreset(name: "Meeting", settings: settings, screens: .mainOnly)
        model.apply(preset)
        XCTAssertEqual(service.currentLayout.enabled, [1, 2])
        XCTAssertEqual(dialogs.keepQuestions, 1)
        XCTAssertEqual(store.value.visibility, .onHover)
        XCTAssertNotNil(model.errorMessage)
        dialogs.keepsDisplays = true
        model.apply(preset)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(service.currentLayout.enabled, [1])
        XCTAssertEqual(store.value.visibility, .hidden)
    }

    func testMissingExternalScreenDoesNotApplyAnyPartOfPreset() {
        let service = FakeDisplayService([DisplayInfo(id: 1, name: "Main", isBuiltin: true, isEnabled: true)])
        let store = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        let model = PresetsViewModel(store: store, displays: DisplaysViewModel(service: service, dialogs: FakeDialogs()))
        var preset = WorkspacePreset(name: "External", settings: AppSettings(), screens: .externalOnly)
        preset.externalDisplayIdentity = "not-connected"
        preset.visibility = .hidden
        model.apply(preset)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(service.applied.isEmpty)
        XCTAssertEqual(store.value.visibility, .onHover)
    }

    func testPreviewMemoryOnlyRemovesDiskFilesAndForcedRefreshBypassesCooldown() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var count = 0
        let store = ThumbnailStore(folder: folder, canCapture: { true }, captureImage: { _ in count += 1; return image })
        var cancellables: Set<AnyCancellable> = []
        func capture(force: Bool = false) async {
            let ready = expectation(description: "Preview")
            store.$images.dropFirst().prefix(1).sink { _ in ready.fulfill() }.store(in: &cancellables)
            store.capture(space(1), on: screen, force: force, stillThere: { true })
            await fulfillment(of: [ready], timeout: 2)
        }
        await capture()
        store.flushWrites()
        let file = folder.appendingPathComponent("S1.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotNil(store.dates["S1"])
        let reloaded = ThumbnailStore(folder: folder)
        XCTAssertNotNil(reloaded.dates["S1"])
        try store.setStoresOnDisk(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await capture(force: true)
        XCTAssertEqual(count, 2)
        XCTAssertNotNil(store.images["S1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try store.clear()
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertTrue(store.dates.isEmpty)
    }

    func testClearCacheRejectsPendingCapture() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var pending: CheckedContinuation<CGImage?, Never>?
        let started = expectation(description: "Capture started")
        let store = ThumbnailStore(folder: folder, canCapture: { true }, captureImage: { _ in
            await withCheckedContinuation { pending = $0; started.fulfill() }
        })
        store.capture(space(1), on: screen, stillThere: { true })
        await fulfillment(of: [started], timeout: 2)
        try store.clear()
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pending?.resume(returning: context.makeImage())
        // Allow the suspended capture and its actor continuation to finish.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.images.isEmpty)
        XCTAssertTrue(store.dates.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("S1.jpg").path))
    }
}

@MainActor
private final class HistorySwitcher: SpaceSwitching {
    var visits: [String] = []
    func go(to space: DesktopSpace) -> SpaceSwitcher.Outcome { visits.append(space.id); return .switching }
    func spaceDidChange() {}
}
