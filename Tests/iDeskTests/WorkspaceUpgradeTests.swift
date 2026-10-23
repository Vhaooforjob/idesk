import AppKit
import XCTest
@testable import iDesk

@MainActor
final class WorkspaceUpgradeTests: XCTestCase {
    func testNewWindowEventDoesNotCancelInFlightVerification() async {
        let observer = WindowEventObserver()
        let finished = expectation(description: "In-flight verification completes")
        var deliveries = 0
        observer.onChange = {
            deliveries += 1
            guard deliveries == 1 else { return }
            observer.changed()
            do {
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertFalse(Task.isCancelled)
            } catch { XCTFail("New events must not cancel an operation already started: \(error)") }
            finished.fulfill()
        }
        observer.start()
        defer { observer.stop(); observer.onChange = nil }
        observer.changed()
        await fulfillment(of: [finished], timeout: 5)
    }

    func testPaletteFiltersPrefixesGroupsTagsAndRanksPinsBeforeHistory() {
        typealias Entry = CommandPaletteModel.Entry
        let entries = [
            Entry(id: "desktop:work", title: "Work", detail: "Work swift", symbol: "", kind: .desktop, run: {}),
            Entry(id: "desktop:home", title: "Home", detail: "Personal", symbol: "", kind: .desktop, run: {}),
            Entry(id: "preset:meeting", title: "Meeting", detail: "Preset", symbol: "", kind: .preset, run: {}),
            Entry(id: "window:1", title: "Document", detail: "Editor", symbol: "", kind: .window, run: {}),
            Entry(id: "action:line", title: "Toggle", detail: "Action", symbol: "", kind: .action, run: {})]
        var settings = AppSettings()
        settings.workspace.organization["work"] = DesktopOrganization(group: "Work", tags: "swift", favorite: true)
        settings.workspace.pinnedCommands = ["action:line"]
        settings.workspace.recentCommands = ["preset:meeting"]
        func filter(_ query: String = "", group: String = "", favorites: Bool = false) -> [String] {
            CommandPaletteModel.filter(entries, query: query, group: group, favoritesOnly: favorites,
                                       settings: settings, visitedDesktopIDs: ["home"]).map(\.id)
        }
        XCTAssertEqual(filter(">Meeting"), ["preset:meeting"])
        XCTAssertEqual(filter("> Meeting "), ["preset:meeting"])
        XCTAssertEqual(filter("@Editor"), ["window:1"])
        XCTAssertEqual(filter("swift"), ["desktop:work"])
        XCTAssertEqual(filter(group: "Work"), ["desktop:work"])
        XCTAssertEqual(Set(filter(favorites: true)), ["desktop:work", "action:line"])
        XCTAssertEqual(filter().suffix(3), ["preset:meeting", "desktop:home", "window:1"])
    }

    func testAdaptiveLayoutPreservesRelativeGeometryAcrossDifferentDisplays() throws {
        let original = CGRect(x: -1600, y: 40, width: 800, height: 860)
        let bounds = CGRect(x: -1600, y: 40, width: 1600, height: 860)
        let normalized = try XCTUnwrap(AdaptiveWindowFrame.normalize(original, in: bounds))
        XCTAssertEqual(normalized, CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let newBounds = CGRect(x: 0, y: 25, width: 2400, height: 1300)
        XCTAssertEqual(AdaptiveWindowFrame.resolve(normalized, absolute: original, in: newBounds), CGRect(x: 0, y: 25, width: 1200, height: 1300))
    }
    func testAdaptiveLayoutRejectsInvalidGeometryAndSupportsOldSessions() throws {
        let old = SavedWindowPlacement(bundleID: "app", title: "Document", desktopID: "space", frame: CGRect(x: 1, y: 2, width: 300, height: 200))
        let decoded = try JSONDecoder().decode(SavedWindowPlacement.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.normalizedFrame)
        XCTAssertEqual(AdaptiveWindowFrame.resolve(nil, absolute: old.frame, in: nil), old.frame)
        XCTAssertNil(AdaptiveWindowFrame.normalize(.zero, in: CGRect(x: 0, y: 0, width: 1000, height: 800)))
        XCTAssertNil(AdaptiveWindowFrame.normalize(CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), in: .zero))
    }
    func testQuickLayoutsStayWithinUsableBoundsAndGridDoesNotOverlap() {
        let bounds = CGRect(x: -1920, y: 30, width: 1920, height: 1050)
        let original = CGRect(x: 20, y: 20, width: 800, height: 600)
        for layout in WindowArrangement.allCases {
            XCTAssertTrue(bounds.contains(layout.frame(in: bounds, original: original, index: 0)))
        }
        let cells = (0..<4).map { WindowArrangement.grid.frame(in: bounds, original: original, index: $0) }
        XCTAssertEqual(cells.reduce(0) { $0 + $1.width * $1.height }, bounds.width * bounds.height)
        XCTAssertEqual(Set(cells.map { "\($0.minX):\($0.minY)" }).count, 4)
    }
    func testContextRulesChoosePriorityAndRespectCooldownAndDisabledRules() {
        let now = Date()
        var low = ContextPresetRule(presetID: "low"); low.isEnabled = true; low.priority = 1
        var high = ContextPresetRule(presetID: "high"); high.isEnabled = true; high.priority = 5; high.match = "app.editor"
        var disabled = ContextPresetRule(presetID: "disabled"); disabled.priority = 100
        XCTAssertEqual(ContextPresetService.choose(rules: [low, disabled, high], event: .appLaunched, match: "app.editor", lastRuns: [:], now: now)?.presetID, "high")
        XCTAssertEqual(ContextPresetService.choose(rules: [low, high], event: .appLaunched, match: "app.editor", lastRuns: [high.id: now], now: now)?.presetID, "low")
        XCTAssertEqual(ContextPresetService.choose(rules: [low, high], event: .appLaunched, match: "app.other", lastRuns: [:], now: now)?.presetID, "low")
        XCTAssertNil(ContextPresetService.choose(rules: [low, high], event: .displayConnected, match: "", lastRuns: [:], now: now))
    }
    func testNewWorkspacePreferencesRoundTripAndOlderSettingsRemainPaused() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.workspace.automationPaused)
        var settings = old
        settings.workspace.organization["desktop"] = DesktopOrganization(group: "Work", tags: "coding swift", favorite: true)
        settings.workspace.contextRules = [ContextPresetRule(presetID: "preset")]
        settings.workspace.pinnedCommands = ["action:line"]
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testImportRemapsOrganizationAndNeverEnablesAutomaticActions() throws {
        var settings = AppSettings()
        settings.workspace.automationPaused = false
        settings.workspace.organization["old"] = DesktopOrganization(group: "Work", tags: "", favorite: true)
        settings.workspace.contextRules = [ContextPresetRule(presetID: "preset", isEnabled: true)]
        settings.workspace.pinnedCommands = ["desktop:old"]
        let space = DesktopSpace(id: "old", managedID: 1, displayID: "screen", kind: .desktop, position: 0, number: 1, ownerName: nil, isCurrent: true)
        let archive = SettingsArchive(settings: settings, spaces: [space])
        let value = try archive.mapped(using: ["old": "new"], available: ["new"])
        XCTAssertEqual(value.workspace.organization["new"]?.group, "Work")
        XCTAssertNil(value.workspace.organization["old"])
        XCTAssertTrue(value.workspace.automationPaused)
        XCTAssertTrue(value.workspace.contextRules.isEmpty)
        XCTAssertTrue(value.workspace.pinnedCommands.isEmpty)
    }
    func testMinimizedWindowsRemainSearchableButNotMovable() async {
        let window = WindowCandidate(selection: WindowSelection(id: 1, processID: 10, sourceSpaceID: 1), appName: "Editor", title: "Document", isMinimized: true)
        let target = DesktopSpace(id: "two", managedID: 2, displayID: "screen", kind: .desktop, position: 1, number: 2, ownerName: nil, isCurrent: false)
        let model = WindowPickerViewModel(readWindows: { [window] }, readDestinations: { _ in [WindowDestination(space: target, name: "Two")] })
        await model.load()
        XCTAssertEqual(model.filteredWindows.count, 1)
        XCTAssertNotNil(model.selectedWindow)
        XCTAssertTrue(model.destinations.isEmpty)
        XCTAssertNil(model.batchRequest)
        XCTAssertNil(model.moveRequest)
    }
    func testUpdateVersionsCompareNumericallyAndRejectPrereleaseOrUnknownTags() {
        XCTAssertTrue(UpdateService.isNewer("v1.10.0", than: "1.9.9"))
        XCTAssertFalse(UpdateService.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateService.isNewer("v2.0-beta", than: "1.2.1"))
        XCTAssertFalse(UpdateService.isNewer("latest", than: "1.2.1"))
        XCTAssertFalse(UpdateService.isNewer("1..3", than: "1.2.1"))
        XCTAssertFalse(UpdateService.isNewer("1.1", than: "1.2.1"))
    }
    func testUpdaterOnlyOpensRepositoryReleaseURLsAndRequiresRealSigningConfiguration() {
        XCTAssertTrue(UpdateService.trustedReleaseURL(URL(string: "https://github.com/Vhaooforjob/idesk/releases/tag/v2.0")!))
        for address in ["https://github.com.evil.test/Vhaooforjob/idesk/releases/tag/v2", "http://github.com/Vhaooforjob/idesk/releases/tag/v2", "https://github.com/else/idesk/releases/tag/v2"] {
            XCTAssertFalse(UpdateService.trustedReleaseURL(URL(string: address)!))
        }
        XCTAssertNil(SignedUpdateConfiguration(info: [:]))
        XCTAssertNil(SignedUpdateConfiguration(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "placeholder"]))
        XCTAssertNotNil(SignedUpdateConfiguration(info: ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]))
    }
    func testOperationRetryIsSingleUseAndDiagnosticsExcludeUserContent() async {
        let journal = OperationJournal()
        var retries = 0
        journal.record("Move Window", item: "SECRET DOCUMENT", error: WorkspaceFeatureError(message: "SECRET URL"), retry: { retries += 1 })
        XCTAssertFalse(journal.diagnosticSummary.contains("SECRET"))
        let entry = journal.entries[0]
        await journal.retry(entry)
        await journal.retry(entry)
        XCTAssertEqual(retries, 1)
        XCTAssertNil(journal.entries[0].retry)
        journal.clear()
        XCTAssertTrue(journal.entries.isEmpty)
    }
}
