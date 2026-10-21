import AppKit
import Carbon
import XCTest
@testable import iDesk

/// The menu bar item, unreadable settings, switch failures, sleeping Spaces
/// polling and the extra shortcut keys.
@MainActor
final class PolishTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iDesk-Polish-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func space(_ number: Int, current: Bool = false) -> DesktopSpace {
        DesktopSpace(id: "S\(number)", managedID: number, displayID: "Main", kind: .desktop, position: number - 1,
                     number: number, ownerName: nil, isCurrent: current)
    }

    // MARK: Menu bar item

    func testMenuBarIconIsATemplateAndNeverTinted() {
        let button = NSButton()
        // An earlier build tinted the button with the desktop's color.
        button.contentTintColor = .systemOrange
        MenuBarController.configureIcon(of: button, symbol: "rectangle.on.rectangle")
        XCTAssertNil(button.contentTintColor, "A tint replaces the status bar's automatic foreground for the icon and the name.")
        XCTAssertEqual(button.image?.isTemplate, true)
    }

    func testLongTitlesAreCutButTheTooltipKeepsTheWholeName() {
        let name = "Quarterly planning and budget review"
        let button = NSButton()
        MenuBarController.configureTitle(of: button, title: name, name: name)
        XCTAssertLessThanOrEqual(button.title.count, 1 + MenuBarViewModel.titleLimit)
        XCTAssertTrue(button.title.hasSuffix("…"))
        XCTAssertEqual(button.toolTip, name)
        XCTAssertEqual(button.accessibilityLabel(), "iDesk, \(name)")
        XCTAssertEqual(button.imagePosition, .imageLeading)

        MenuBarController.configureTitle(of: button, title: "Work", name: "Work")
        XCTAssertEqual(button.title, " Work")
    }

    func testIconOnlyTitleStillNamesTheDesktopForTooltipAndVoiceOver() {
        let button = NSButton()
        MenuBarController.configureTitle(of: button, title: "", name: "Music")
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.toolTip, "Music")
        MenuBarController.configureTitle(of: button, title: "", name: "")
        XCTAssertNil(button.toolTip)
        XCTAssertEqual(button.accessibilityLabel(), "iDesk")
    }

    func testShortenedLeavesShortTitlesAndTrimsBeforeTheEllipsis() {
        XCTAssertEqual(MenuBarViewModel.shortened("Work"), "Work")
        XCTAssertEqual(MenuBarViewModel.shortened(String(repeating: "a", count: 24)), String(repeating: "a", count: 24))
        XCTAssertEqual(MenuBarViewModel.shortened("abcd efgh", limit: 6), "abcd…")
        XCTAssertEqual(MenuBarViewModel.shortened("Tên desktop rất dài", limit: 8), "Tên des…")
    }

    // MARK: Settings

    func testUnreadableSettingsAreKeptBesideTheNewFileInsteadOfOverwritten() throws {
        let file = folder.appendingPathComponent("settings.json")
        let damaged = Data("{\"names\": {\"S1\": \"Work\"".utf8)
        try damaged.write(to: file)
        let store = SettingsStore(fileURL: file)
        XCTAssertEqual(store.value.names, [:])
        XCTAssertEqual(try Data(contentsOf: SettingsStore.backupURL(for: file)), damaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        store.value.names["S1"] = "Home"
        try store.saveNow()
        XCTAssertEqual(try Data(contentsOf: SettingsStore.backupURL(for: file)), damaged)
        XCTAssertEqual(SettingsStore(fileURL: file).value.names["S1"], "Home")
    }

    func testReadableAndMissingSettingsLeaveNoBackup() throws {
        let file = folder.appendingPathComponent("settings.json")
        _ = SettingsStore(fileURL: file)
        let store = SettingsStore(fileURL: file)
        store.value.names["S1"] = "Work"
        try store.saveNow()
        XCTAssertEqual(SettingsStore(fileURL: file).value.names["S1"], "Work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SettingsStore.backupURL(for: file).path))
    }

    // MARK: Switching

    func testSwitchFailureIsReportedOnlyWhenTheDesktopNeverBecomesCurrent() {
        var source = [space(1, current: true), space(2)]
        let service = SpaceService(read: { source })
        service.reload()
        let switcher = SpaceSwitcher(spaces: service)
        var failed: [String] = []
        switcher.onFailure = { failed.append($0.id) }

        switcher.expectArrival(at: space(2), within: 3600)
        switcher.confirmArrival(at: space(2))
        XCTAssertEqual(failed, ["S2"])

        // Arrived in time: nothing to report.
        source = [space(1), space(2, current: true)]
        switcher.expectArrival(at: space(2), within: 3600)
        switcher.confirmArrival(at: space(2))
        XCTAssertEqual(failed, ["S2"])

        // A newer request replaces the older one's check.
        source = [space(1, current: true), space(2), space(3)]
        switcher.expectArrival(at: space(2), within: 3600)
        switcher.expectArrival(at: space(3), within: 3600)
        switcher.confirmArrival(at: space(2))
        XCTAssertEqual(failed, ["S2"])
        switcher.confirmArrival(at: space(3))
        XCTAssertEqual(failed, ["S2", "S3"])
    }

    func testSwitchFailureAsksTheUserWithTheDesktopName() {
        let service = SpaceService(read: { [self.space(1, current: true), self.space(2)] })
        service.reload()
        let dialogs = FakeDialogs()
        let store = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        let desktops = DesktopsViewModel(spaceService: service, thumbnailStore: ThumbnailStore(folder: folder),
            settingsStore: store, switcher: SpaceSwitcher(spaces: service), desktopManager: FakeDesktopManager(), dialogs: dialogs)
        desktops.switchFailed(to: space(2))
        XCTAssertEqual(dialogs.errors.count, 1)
        XCTAssertTrue(dialogs.errors[0].contains("Desktop 2"))
    }

    // MARK: Polling

    func testPollingStopsWhileScreensSleepAndCatchesUpOnWake() {
        var source = [space(1, current: true)]
        var reads = 0
        let service = SpaceService(read: { reads += 1; return source })
        service.start()
        defer { service.pausePolling() }
        XCTAssertTrue(service.isPolling)
        service.pausePolling()
        XCTAssertFalse(service.isPolling)
        source = [space(1, current: true), space(2)]
        let before = reads
        service.resumePolling()
        XCTAssertTrue(service.isPolling)
        XCTAssertEqual(reads, before + 1, "Waking reads the Spaces once at once.")
        XCTAssertEqual(service.spaces.count, 2)
        service.resumePolling()
        XCTAssertEqual(reads, before + 1, "Resuming twice must not start a second timer or read again.")
    }

    // MARK: Shortcut keys

    func testMinusBacktickArrowsTabAndReturnCanBeUsed() {
        XCTAssertEqual(HotkeyService.parse("⌃⌥-")?.keyCode, 27)
        XCTAssertEqual(HotkeyService.parse("ctrl+option+-")?.keyCode, 27)
        XCTAssertEqual(HotkeyService.parse("ctrl--")?.keyCode, 27)
        XCTAssertEqual(HotkeyService.parse("⌃⌥`")?.keyCode, 50)
        XCTAssertEqual(HotkeyService.parse("⌃⌥←")?.keyCode, 123)
        XCTAssertEqual(HotkeyService.parse("⌃⌥→")?.keyCode, 124)
        XCTAssertEqual(HotkeyService.parse("⌃⌥↓")?.keyCode, 125)
        XCTAssertEqual(HotkeyService.parse("⌃⌥↑")?.keyCode, 126)
        XCTAssertEqual(HotkeyService.parse("⌃⌥⇥")?.keyCode, 48)
        XCTAssertEqual(HotkeyService.parse("⌃⌥↩")?.keyCode, 36)
        XCTAssertEqual(HotkeyService.parse("ctrl+option+left")?.keyCode, 123)
        XCTAssertEqual(HotkeyService.parse("ctrl+option+Tab")?.keyCode, 48)
        XCTAssertEqual(HotkeyService.parse("ctrl+option+enter")?.keyCode, 36)
        XCTAssertEqual(HotkeyService.parse("⌃⌥-")?.modifiers, HotkeyService.parse("ctrl+option+M")?.modifiers)
    }

    func testDashStillSeparatesWordsAndNeedsAModifier() {
        XCTAssertEqual(HotkeyService.parse("ctrl-option-M")?.keyCode, 46)
        XCTAssertNil(HotkeyService.parse("ctrl-"), "A dash after a word is a separator, not the minus key.")
        XCTAssertNil(HotkeyService.parse("-"))
        XCTAssertNil(HotkeyService.parse("⇧-"))
    }

    func testRecordedKeysAreNamedTheSameWayTheyAreRead() {
        for (code, name) in [(27, "-"), (50, "`"), (123, "←"), (124, "→"), (125, "↓"), (126, "↑"), (48, "⇥"), (36, "↩")] as [(UInt16, String)] {
            XCTAssertEqual(HotkeyService.keyName(for: code), name)
            XCTAssertEqual(HotkeyService.parse("⌃⌥" + name)?.keyCode, UInt32(code))
        }
    }

    func testShortcutsMacOSUsesToSwitchDesktopsAreRejected() {
        let reserved = [KeyShortcut(keyCode: 123, flags: [.maskControl, .maskSecondaryFn]),
                        KeyShortcut(keyCode: 18, flags: .maskControl)]
        let errors = HotkeyService.validationErrors([.toggleLine: "⌃←", .renameCurrent: "⌃1", .moveWindow: "⌃⌥←"], reserved: reserved)
        XCTAssertEqual(Set(errors.keys), [.toggleLine, .renameCurrent])
        XCTAssertTrue(HotkeyService.validationErrors([.toggleLine: "⌃⌥D"], reserved: reserved).isEmpty)
    }

    func testSwitchingShortcutsComeFromTheSystemTable() {
        let table: [String: Any] = [
            "79": ["enabled": true, "value": ["parameters": [65535, 123, 8650752]]],
            "81": ["enabled": false],
            "118": ["enabled": true, "value": ["parameters": [49, 18, 262144]]]
        ]
        let reserved = SymbolicHotkeys.switching(in: table)
        XCTAssertTrue(reserved.contains(KeyShortcut(keyCode: 123, flags: CGEventFlags(rawValue: 8650752))))
        XCTAssertTrue(reserved.contains(KeyShortcut(keyCode: 18, flags: CGEventFlags(rawValue: 262144))))
        XCTAssertFalse(reserved.contains { $0.keyCode == 124 })
        XCTAssertEqual(KeyShortcut(keyCode: 123, flags: CGEventFlags(rawValue: 8650752)).carbonModifiers, UInt32(controlKey))
    }

    func testMenuHintSkipsSpecialKeys() {
        let arrow = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        arrow.showShortcut("⌃⌥←")
        XCTAssertEqual(arrow.keyEquivalent, "")
        let minus = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        minus.showShortcut("⌃⌥-")
        XCTAssertEqual(minus.keyEquivalent, "-")
    }

    // MARK: Preview files

    func testPreviewIsWrittenInTheBackgroundAndClearingNeverLeavesItBehind() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let store = ThumbnailStore(folder: folder, canCapture: { true }, captureImage: { _ in image })
        let saved = expectation(description: "Preview")
        let observer = store.$images.dropFirst().prefix(1).sink { _ in saved.fulfill() }
        store.capture(space(1), on: screen, stillThere: { true })
        await fulfillment(of: [saved], timeout: 2)
        observer.cancel()
        // Clear waits for the queued write, then removes the file it wrote.
        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("S1.jpg").path))
        store.flushWrites()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("S1.jpg").path))
    }
}
