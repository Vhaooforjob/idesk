import CoreGraphics
import XCTest
@testable import iDesk

final class ScreenColorTests: XCTestCase {
    func testNeutralWarmthAndFullBrightnessChangeNothing() {
        let gain = ScreenColor.gain(brightness: 1, warmth: 0)
        XCTAssertEqual(gain.red, 1, accuracy: 0.0001)
        XCTAssertEqual(gain.green, 1, accuracy: 0.0001)
        XCTAssertEqual(gain.blue, 1, accuracy: 0.0001)
    }

    func testWarmthLowersBlueMoreThanGreenAndKeepsRed() {
        let gain = ScreenColor.gain(brightness: 1, warmth: 1)
        XCTAssertEqual(gain.red, 1, accuracy: 0.0001)
        XCTAssertLessThan(gain.green, 1)
        XCTAssertLessThan(gain.blue, gain.green)
        XCTAssertGreaterThan(gain.blue, 0.1, "the warmest setting still shows blue")
    }

    func testWarmthGrowsStepByStep() {
        let blues = stride(from: 0.0, through: 1.0, by: 0.25).map { ScreenColor.gain(brightness: 1, warmth: $0).blue }
        XCTAssertEqual(blues, blues.sorted(by: >))
    }

    func testBrightnessScalesEveryChannelAndNeverReachesBlack() {
        let half = ScreenColor.gain(brightness: 0.5, warmth: 0)
        XCTAssertEqual(half.red, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.blue, 0.5 * ScreenColor.gain(brightness: 1, warmth: 0).blue, accuracy: 0.0001)
        let floor = ScreenColor.gain(brightness: 0, warmth: 0)
        XCTAssertEqual(floor.red, ScreenColor.minimumBrightness, accuracy: 0.0001)
        let over = ScreenColor.gain(brightness: 5, warmth: 9)
        XCTAssertLessThanOrEqual(max(over.red, over.green, over.blue), 1)
    }
}

final class ScreenTuningModelTests: XCTestCase {
    func testValuesAreClamped() {
        let tuning = ScreenTuning(softwareBrightness: -3, warmth: 7)
        XCTAssertEqual(tuning.softwareBrightness, ScreenColor.minimumBrightness)
        XCTAssertEqual(tuning.warmth, 1)
        XCTAssertEqual(ScreenTuning(softwareBrightness: .nan, warmth: .infinity).warmth, 0)
    }

    func testNeutralMeansNothingToApply() {
        XCTAssertTrue(ScreenTuning().isNeutral)
        XCTAssertFalse(ScreenTuning(warmth: 0.2).isNeutral)
        XCTAssertFalse(ScreenTuning(softwareBrightness: 0.8).isNeutral)
    }

    func testOldSettingsWithoutTuningStillLoad() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.screenTuning, [:])
        let partial = try JSONDecoder().decode(ScreenTuning.self, from: Data(#"{"warmth":0.4}"#.utf8))
        XCTAssertEqual(partial, ScreenTuning(softwareBrightness: 1, warmth: 0.4))
    }

    func testTuningSurvivesASaveAndLoad() throws {
        var settings = AppSettings()
        settings.screenTuning["A"] = ScreenTuning(softwareBrightness: 0.6, warmth: 0.3)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(again.screenTuning, settings.screenTuning)
    }
}

final class DDCBusTests: XCTestCase {
    func testReadsTheVendorAndModelFromAnEDIDUUID() {
        let edid = DDCBus.edid(from: "61A90210-0000-0000-0222-010380351E78")
        XCTAssertEqual(edid?.vendor, 0x61A9)
        XCTAssertEqual(edid?.model, 0x1002)
        XCTAssertNil(DDCBus.edid(from: "nope"))
    }

    func testChecksumOfASetCommandMatchesTheSpecExample() {
        // 51 84 03 10 00 32 with destination 6E: the XOR of all bytes.
        let command: [UInt8] = [0x84, 0x03, 0x10, 0x00, 0x32]
        XCTAssertEqual(DDCBus.checksum(of: command, seed: 0x6E ^ 0x51), 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x32)
    }

    func testParsesAReplyFromARealScreen() {
        // Captured from an external screen at 95 of 100.
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x5F, 0x9F, 0x27]
        XCTAssertEqual(DDCBus.level(from: reply), DDCBus.Level(value: 95, maximum: 100))
    }

    func testRejectsBrokenReplies() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x5F, 0x9F, 0x27]
        reply[9] = 0x20
        XCTAssertNil(DDCBus.level(from: reply), "wrong checksum")
        XCTAssertNil(DDCBus.level(from: [UInt8](repeating: 0, count: 12)), "an empty read")
        XCTAssertNil(DDCBus.level(from: [0x6E, 0x88]), "too short")
        var refused = reply
        refused[3] = 0x01
        XCTAssertNil(DDCBus.level(from: refused), "the screen refused the feature")
    }

    func testMatchesScreensToChannelsByVendorAndModel() {
        let channels: [(vendor: UInt16, model: UInt16)] = [(1, 10), (2, 20)]
        let matches = DDCBus.match(screens: [.init(id: 7, vendor: 2, model: 20), .init(id: 9, vendor: 1, model: 10)], channels: channels)
        XCTAssertEqual(matches, [7: 1, 9: 0])
    }

    func testIdenticalScreensTakeChannelsInOrder() {
        let channels: [(vendor: UInt16, model: UInt16)] = [(1, 10), (1, 10)]
        let matches = DDCBus.match(screens: [.init(id: 9, vendor: 1, model: 10), .init(id: 4, vendor: 1, model: 10)], channels: channels)
        XCTAssertEqual(matches, [4: 0, 9: 1])
    }

    func testALoneScreenWithALoneChannelPairsEvenWithoutAnEDID() {
        XCTAssertEqual(DDCBus.match(screens: [.init(id: 3, vendor: 5, model: 5)], channels: [(0, 0)]), [3: 0])
        XCTAssertEqual(DDCBus.match(screens: [.init(id: 3, vendor: 5, model: 5), .init(id: 4, vendor: 6, model: 6)],
                                    channels: [(0, 0)]), [:], "never guess between several screens")
    }
}

/// A system with screens in memory: no DDC bus, no gamma tables.
@MainActor
final class FakeTuningSystem: ScreenTuningSystem {
    var levels: [CGDirectDisplayID: DDCBus.Level] = [:]
    var written: [(value: Int, id: CGDirectDisplayID)] = []
    var writeSucceeds = true
    var gains: [(gain: ScreenColor.Gain, id: CGDirectDisplayID)] = []
    var restored = 0
    var night: NightShiftStatus? = NightShiftStatus(isOn: false)
    var acceptsNightShift = true

    func identifier(for id: CGDirectDisplayID) -> String? { "UUID-\(id)" }
    func prepareHardware(for ids: [CGDirectDisplayID]) {}
    func hardwareBrightness(of id: CGDirectDisplayID) async -> DDCBus.Level? { levels[id] }

    func setHardwareBrightness(_ value: Int, of id: CGDirectDisplayID) async -> Bool {
        await Task.yield()
        guard writeSucceeds else { return false }
        written.append((value, id))
        levels[id] = DDCBus.Level(value: value, maximum: levels[id]?.maximum ?? 100)
        return true
    }

    func applyGain(_ gain: ScreenColor.Gain, to id: CGDirectDisplayID) { gains.append((gain, id)) }
    func restoreColors() { restored += 1 }
    func nightShiftStatus() -> NightShiftStatus? { night }

    func setNightShift(_ on: Bool) -> Bool {
        guard acceptsNightShift else { return false }
        night = NightShiftStatus(isOn: on)
        return true
    }
}

@MainActor
final class ScreenTuningViewModelTests: XCTestCase {
    private var folder: URL!
    private var store: SettingsStore!
    private var system: FakeTuningSystem!
    private var dialogs: FakeDialogs!
    private var model: ScreenTuningViewModel!

    private let builtIn = DisplayInfo(id: 1, name: "Built-in", isBuiltin: true, isEnabled: true)
    private let monitor = DisplayInfo(id: 3, name: "Monitor", isBuiltin: false, isEnabled: true)
    private let tv = DisplayInfo(id: 5, name: "TV", isBuiltin: false, isEnabled: true)

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("iDeskTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = SettingsStore(fileURL: folder.appendingPathComponent("settings.json"))
        system = FakeTuningSystem()
        dialogs = FakeDialogs()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func make(_ displays: [DisplayInfo]) -> ScreenTuningViewModel {
        let screens = DisplaysViewModel(service: FakeDisplayService(displays), dialogs: dialogs)
        return ScreenTuningViewModel(displays: screens, settingsStore: store, system: system, dialogs: dialogs)
    }

    func testOnlyExternalScreensAreListed() async {
        model = make([builtIn, monitor])
        await model.reload()
        XCTAssertEqual(model.screens.map(\.id), [3])
    }

    func testAScreenThatAnswersDDCUsesItsBacklight() async {
        system.levels[3] = DDCBus.Level(value: 40, maximum: 100)
        model = make([builtIn, monitor])
        await model.reload()
        XCTAssertEqual(model.screens.first?.control, .hardware(maximum: 100))
        XCTAssertEqual(model.screens.first?.brightness ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertTrue(system.gains.isEmpty, "an untouched screen keeps its gamma table")
    }

    func testAScreenThatDoesNotAnswerIsDimmedInSoftware() async {
        model = make([builtIn, monitor])
        await model.reload()
        XCTAssertEqual(model.screens.first?.control, .software)
        model.setBrightness(0.5, for: 3)
        XCTAssertEqual(system.gains.last?.id, 3)
        XCTAssertEqual(system.gains.last?.gain.red ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(store.value.screenTuning["UUID-3"]?.softwareBrightness, 0.5)
    }

    func testSoftwareBrightnessNeverGoesBelowTheFloor() async {
        model = make([builtIn, monitor])
        await model.reload()
        model.setBrightness(0, for: 3)
        XCTAssertEqual(model.screens.first?.brightness, ScreenColor.minimumBrightness)
    }

    func testHardwareBrightnessIsWrittenToTheScreen() async {
        system.levels[3] = DDCBus.Level(value: 90, maximum: 100)
        model = make([builtIn, monitor])
        await model.reload()
        model.setBrightness(0.25, for: 3)
        await model.settle()
        XCTAssertEqual(system.written.map(\.value), [25])
        XCTAssertNil(store.value.screenTuning["UUID-3"], "the screen keeps its own level")
        XCTAssertTrue(system.gains.isEmpty)
    }

    func testDraggingASliderOnlySendsTheNewestLevelsAndEndsOnTheLast() async {
        system.levels[3] = DDCBus.Level(value: 90, maximum: 100)
        model = make([builtIn, monitor])
        await model.reload()
        for step in 1...20 { model.setBrightness(Double(step) / 20, for: 3) }
        await model.settle()
        XCTAssertEqual(system.written.last?.value, 100)
        XCTAssertLessThan(system.written.count, 20, "intermediate levels are dropped")
    }

    func testAScreenThatStopsAnsweringFallsBackToSoftware() async {
        system.levels[3] = DDCBus.Level(value: 90, maximum: 100)
        model = make([builtIn, monitor])
        await model.reload()
        system.writeSucceeds = false
        model.setBrightness(0.3, for: 3)
        await model.settle()
        XCTAssertEqual(model.screens.first?.control, .software)
    }

    func testWarmthIsSavedAndAppliedToThatScreenOnly() async {
        model = make([monitor, tv])
        await model.reload()
        model.setWarmth(0.8, for: 5)
        XCTAssertEqual(system.gains.map(\.id), [5])
        XCTAssertLessThan(system.gains[0].gain.blue, 1)
        XCTAssertEqual(store.value.screenTuning["UUID-5"]?.warmth ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertNil(store.value.screenTuning["UUID-3"])
    }

    func testSavedWarmthComesBackWhenTheScreenIsSeenAgain() async {
        store.value.screenTuning["UUID-3"] = ScreenTuning(softwareBrightness: 0.7, warmth: 0.5)
        model = make([monitor])
        await model.reload()
        XCTAssertEqual(model.screens.first?.warmth, 0.5)
        XCTAssertEqual(model.screens.first?.brightness, 0.7)
        XCTAssertEqual(system.gains.count, 1)
    }

    func testResetGivesTheColorsBackAndForgetsThem() async {
        model = make([monitor])
        await model.reload()
        model.setWarmth(0.6, for: 3)
        model.setBrightness(0.4, for: 3)
        model.resetColors(for: 3)
        XCTAssertEqual(system.gains.last?.gain, .identity)
        XCTAssertNil(store.value.screenTuning["UUID-3"])
        XCTAssertEqual(model.screens.first?.brightness, 1)
        XCTAssertEqual(model.screens.first?.warmth, 0)
    }

    func testResetKeepsAHardwareBacklightWhereItIs() async {
        system.levels[3] = DDCBus.Level(value: 30, maximum: 100)
        model = make([monitor])
        await model.reload()
        model.setWarmth(0.5, for: 3)
        model.resetColors(for: 3)
        XCTAssertEqual(model.screens.first?.brightness ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertTrue(system.written.isEmpty)
    }

    func testQuittingGivesBackTheGammaTableOnlyIfIdeskChangedIt() async {
        model = make([monitor])
        await model.reload()
        model.stop()
        XCTAssertEqual(system.restored, 0)
        model.setWarmth(0.5, for: 3)
        model.stop()
        XCTAssertEqual(system.restored, 1)
    }

    func testNightShiftFollowsTheSystem() async {
        model = make([monitor])
        XCTAssertTrue(model.hasNightShift)
        model.setNightShift(true)
        XCTAssertEqual(model.nightShift, NightShiftStatus(isOn: true))
        XCTAssertTrue(dialogs.errors.isEmpty)
    }

    func testNightShiftThatDoesNotChangeIsReported() async {
        model = make([monitor])
        system.acceptsNightShift = false
        model.setNightShift(true)
        XCTAssertEqual(dialogs.errors.count, 1)
    }

    func testShortcutsStepTheScreenUnderThePointer() async {
        system.levels[3] = DDCBus.Level(value: 50, maximum: 100)
        system.levels[5] = DDCBus.Level(value: 50, maximum: 100)
        model = make([builtIn, monitor, tv])
        await model.reload()
        model.nudgeBrightness(by: ScreenTuningViewModel.keyStep, near: 5)
        await model.settle()
        XCTAssertEqual(system.written.map(\.id), [5])
        XCTAssertEqual(system.written.last?.value, 55)
        model.nudgeBrightness(by: -ScreenTuningViewModel.keyStep, near: 1)
        await model.settle()
        XCTAssertEqual(system.written.last?.id, 3, "the pointer is on the built-in screen: the first external one moves")
        XCTAssertEqual(system.written.last?.value, 45)
    }

    func testShortcutsStopAtTheEnds() async {
        model = make([monitor])
        await model.reload()
        for _ in 0..<40 { model.nudgeBrightness(by: -ScreenTuningViewModel.keyStep, near: 3) }
        XCTAssertEqual(model.screens.first?.brightness, ScreenColor.minimumBrightness)
        for _ in 0..<40 { model.nudgeBrightness(by: ScreenTuningViewModel.keyStep, near: 3) }
        XCTAssertEqual(model.screens.first?.brightness, 1)
    }

    func testShortcutsDoNothingWithoutAnExternalScreen() async {
        model = make([builtIn])
        await model.reload()
        model.nudgeBrightness(by: 0.05, near: 1)
        XCTAssertTrue(system.gains.isEmpty)
        XCTAssertTrue(system.written.isEmpty)
    }

    func testNightShiftShortcutFlipsTheSwitch() async {
        model = make([monitor])
        model.toggleNightShift()
        XCTAssertEqual(model.nightShift, NightShiftStatus(isOn: true))
        model.toggleNightShift()
        XCTAssertEqual(model.nightShift, NightShiftStatus(isOn: false))
    }

    func testTheNewShortcutsHaveNoConflictsByDefault() {
        let shortcuts = HotkeyService.shortcuts(in: AppSettings())
        XCTAssertEqual(shortcuts[.brightnessUp], "⌃⌥↑")
        XCTAssertNotNil(HotkeyService.parse(shortcuts[.brightnessDown] ?? ""))
        XCTAssertTrue(HotkeyService.validationErrors(shortcuts).isEmpty)
    }

    func testNightShiftIsHiddenWhenMacOSHasNone() async {
        system.night = nil
        model = make([monitor])
        XCTAssertFalse(model.hasNightShift)
    }
}
