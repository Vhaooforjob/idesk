import AppKit
import XCTest
@testable import iDesk

@MainActor
final class WorkspaceFeaturesTests: XCTestCase {
    private func space(_ id: String, number: Int = 1) -> DesktopSpace {
        DesktopSpace(id: id, managedID: number, displayID: "A", kind: .desktop,
                     position: number - 1, number: number, ownerName: nil, isCurrent: number == 1)
    }

    private func window(_ id: UInt32, source: Int = 1, title: String = "Document", bundle: String = "app.editor") -> WindowCandidate {
        WindowCandidate(selection: WindowSelection(id: id, processID: 123, sourceSpaceID: source),
                        appName: "Editor", title: title, bundleID: bundle)
    }

    func testOldSettingsAndPresetsDecodeWithoutLosingNames() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"names":{"old":"Code"}}"#.utf8))
        XCTAssertEqual(settings.names["old"], "Code")
        XCTAssertTrue(settings.windowRules.isEmpty)
        XCTAssertTrue(settings.privateDesktopIDs.isEmpty)
        var preset = WorkspacePreset(name: "Code", settings: settings)
        preset.session = WorkspaceSession(launchItems: [.init(address: "https://example.com", name: "Docs")])
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preset)) as? [String: Any])
        values.removeValue(forKey: "session")
        values.removeValue(forKey: "lineLayout")
        let old = try JSONDecoder().decode(WorkspacePreset.self, from: JSONSerialization.data(withJSONObject: values))
        XCTAssertNil(old.session)
        XCTAssertEqual(old.name, "Code")
    }

    func testAllNewSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.desktopHotkeys = ["old": "⌃⌥1"]
        settings.privateDesktopIDs = ["old"]
        settings.lineLayout = .grid
        settings.windowRules = [WindowRule(bundleID: "app.editor", appName: "Editor", desktopID: "old")]
        var preset = WorkspacePreset(name: "Session", settings: settings)
        preset.session = WorkspaceSession(launchItems: [.init(address: "file:///tmp/project", name: "Project")],
            windows: [.init(bundleID: "app.editor", title: "Document", desktopID: "old", frame: CGRect(x: 1, y: 2, width: 500, height: 400))])
        settings.presets = [preset]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testDesktopShortcutsConflictWithGlobalAndOtherDesktopActions() {
        var settings = AppSettings()
        settings.desktopHotkeys = ["one": settings.moveWindowHotkey, "two": "⌃⌥1", "three": "ctrl+option+1"]
        let errors = HotkeyService.validationErrors(HotkeyService.shortcuts(in: settings), reserved: [])
        XCTAssertNotNil(errors[.moveWindow])
        XCTAssertNotNil(errors[.desktop("one")])
        XCTAssertNotNil(errors[.desktop("two")])
        XCTAssertNotNil(errors[.desktop("three")])
        XCTAssertNil(errors[.undoMove])
    }

    func testArchiveRemapsEveryDesktopReferenceAndDisablesRules() throws {
        var settings = AppSettings()
        settings.names = ["old": "Code", "skip": "Personal"]
        settings.desktopHotkeys = ["old": "⌃⌥1"]
        settings.privateDesktopIDs = ["old", "skip"]
        settings.windowRules = [WindowRule(bundleID: "app.editor", appName: "Editor", desktopID: "old")]
        var preset = WorkspacePreset(name: "Session", settings: settings)
        preset.session = WorkspaceSession(windows: [
            .init(bundleID: "app.editor", title: "A", desktopID: "old"),
            .init(bundleID: "app.editor", title: "B", desktopID: "skip")])
        settings.presets = [preset]
        let archive = SettingsArchive(settings: settings, spaces: [space("old"), space("skip", number: 2)])
        let decoded = try SettingsArchive.read(archive.data())
        let value = try decoded.mapped(using: ["old": "new", "skip": ""], available: ["new"])
        XCTAssertEqual(value.names, ["new": "Code"])
        XCTAssertEqual(value.desktopHotkeys, ["new": "⌃⌥1"])
        XCTAssertEqual(value.privateDesktopIDs, ["new"])
        XCTAssertEqual(value.windowRules.first?.desktopID, "new")
        XCTAssertEqual(value.windowRules.first?.isEnabled, false)
        XCTAssertEqual(value.presets.first?.session?.windows.map(\.desktopID), ["new"])
    }

    func testArchiveRejectsUnknownVersionDuplicateAndMissingMappings() throws {
        var archive = SettingsArchive(settings: AppSettings(), spaces: [space("one"), space("two", number: 2)])
        XCTAssertThrowsError(try archive.mapped(using: ["one": "new", "two": "new"], available: ["new"]))
        XCTAssertThrowsError(try archive.mapped(using: ["one": "missing"], available: ["new"]))
        XCTAssertThrowsError(try archive.mapped(using: ["unknown": "new"], available: ["new"]))
        archive.version = 99
        XCTAssertThrowsError(try SettingsArchive.read(archive.data()))
        XCTAssertThrowsError(try SettingsArchive.read(Data("{}".utf8)))
    }

    func testSaveFailureIsPublishedAndRetryClearsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("block directory creation".utf8).write(to: folder)
        let store = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        store.value.names["one"] = "Code"
        XCTAssertThrowsError(try store.saveNow())
        XCTAssertNotNil(store.saveError)
        try FileManager.default.removeItem(at: folder)
        store.retrySave()
        XCTAssertNil(store.saveError)
        XCTAssertEqual(SettingsStore(fileURL: folder.appendingPathComponent("settings.json")).value.names["one"], "Code")
    }

    func testImportWriteFailureRestoresPreviousSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder)
        let store = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        let old = store.value
        var changed = old
        changed.names["one"] = "Imported"
        XCTAssertThrowsError(try store.replace(with: changed))
        XCTAssertEqual(store.value, old)
    }

    func testBatchPickerIntersectsDestinationsAndDropsHiddenSelections() async {
        let windows = [window(1), window(2, source: 2)]
        let model = WindowPickerViewModel(readWindows: { windows }, readDestinations: { selection in
            (1...3).filter { $0 != selection.sourceSpaceID }.map {
                WindowDestination(space: self.space("S\($0)", number: $0), name: "Desktop \($0)")
            }
        })
        await model.load()
        model.checkedWindowIDs = [1, 2]
        XCTAssertEqual(model.destinations.map(\.id), ["S3"])
        XCTAssertEqual(model.batchRequest?.windows.map(\.id), [1, 2])
        model.query = "no match"
        XCTAssertTrue(model.checkedWindowIDs.isEmpty)
        XCTAssertNil(model.batchRequest)
    }

    func testSessionMatchesExactTitlesAndRejectsAmbiguousAppWindows() {
        let saved = SavedWindowPlacement(bundleID: "app.editor", title: "Document", desktopID: "one")
        XCTAssertEqual(WorkspaceSessionService.match(saved, in: [window(1), window(2, title: "Other")], allowSingleWindowFallback: false)?.id, 1)
        XCTAssertNil(WorkspaceSessionService.match(saved, in: [window(1), window(2)], allowSingleWindowFallback: true))
        XCTAssertNil(WorkspaceSessionService.match(saved, in: [window(1, title: "Other")], allowSingleWindowFallback: false))
        XCTAssertEqual(WorkspaceSessionService.match(saved, in: [window(1, title: "Other")], allowSingleWindowFallback: true)?.id, 1)
    }

    func testSessionFramesStayInsideAvailableScreen() {
        let bounds = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
        let frame = WorkspaceSessionService.clamp(CGRect(x: 9000, y: -500, width: 3000, height: 2000), to: bounds)
        XCTAssertEqual(frame, bounds)
    }

    func testRulesMatchBundleAndTitleInOrderAndRespectDisabledState() {
        let wrong = WindowRule(bundleID: "app.browser", appName: "Browser", desktopID: "other")
        var disabled = WindowRule(bundleID: "app.editor", appName: "Editor", desktopID: "disabled")
        disabled.isEnabled = false
        let specific = WindowRule(bundleID: "app.editor", appName: "Editor", titleContains: "DOC", desktopID: "code")
        let fallback = WindowRule(bundleID: "app.editor", appName: "Editor", desktopID: "fallback")
        XCTAssertEqual(WindowRuleService.matchingRule(for: window(1), rules: [wrong, disabled, specific, fallback])?.desktopID, "code")
        XCTAssertEqual(WindowRuleService.matchingRule(for: window(1, title: "Other"), rules: [specific, fallback])?.desktopID, "fallback")
    }

    func testLayoutNeverProducesNegativeScaleWhileThePanelIsBeingSized() {
        for width: CGFloat in [0, 20, 60, 200, 1920] {
            for count in [0, 1, 20] {
                XCTAssertGreaterThanOrEqual(LineLayout.scale(count: count, width: width), 0)
                XCTAssertLessThanOrEqual(LineLayout.scale(count: count, width: width), 1)
            }
        }
    }

    func testSessionLaunchItemsRejectExecutableSchemes() {
        for address in ["javascript:alert(1)", "shell:rm", "https:", "/tmp/project"] {
            XCTAssertNil(SessionLaunchItem(address: address, name: "Item").url)
        }
        XCTAssertNotNil(SessionLaunchItem(address: "https://example.com", name: "Docs").url)
        XCTAssertNotNil(SessionLaunchItem(address: "file:///tmp/project", name: "Project").url)
    }

    func testPrivatePreviewPurgesMemoryAndDiskWithoutDeletingOtherDesktops() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        try data.write(to: folder.appendingPathComponent("private.jpg"))
        try data.write(to: folder.appendingPathComponent("public.jpg"))
        let store = ThumbnailStore(folder: folder)
        XCTAssertNotNil(store.images["private"])
        try store.setPrivateSpaces(["private"])
        XCTAssertNil(store.images["private"])
        XCTAssertNil(store.dates["private"])
        XCTAssertNotNil(store.images["public"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("private.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("public.jpg").path))
    }
}
