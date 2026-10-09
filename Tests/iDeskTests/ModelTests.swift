import CoreGraphics
import XCTest
@testable import iDesk

final class SpaceLayoutTests: XCTestCase {
    private func space(_ id: Int, type: Int = 0, uuid: String? = nil) -> [String: Any] {
        ["ManagedSpaceID": id, "type": type, "uuid": uuid ?? "UUID-\(id)"]
    }

    func testNumbersDesktopsAcrossDisplaysAndSkipsFullScreen() {
        let displays: [[String: Any]] = [
            [
                "Display Identifier": "A",
                "Current Space": ["ManagedSpaceID": 3],
                "Spaces": [space(1, uuid: ""), space(2, type: 4), space(3)]
            ],
            [
                "Display Identifier": "B",
                "Current Space": ["ManagedSpaceID": 7],
                "Spaces": [space(7), space(8)]
            ]
        ]
        let spaces = SpaceLayout.parse(displays)
        XCTAssertEqual(spaces.map(\.number), [1, nil, 2, 3, 4])
        XCTAssertEqual(spaces.map(\.position), [0, 1, 2, 0, 1])
        XCTAssertEqual(spaces.map(\.kind), [.desktop, .fullScreen, .desktop, .desktop, .desktop])
        XCTAssertEqual(spaces.filter(\.isCurrent).map(\.managedID), [3, 7])
        // A display's original desktop may have no UUID.
        XCTAssertEqual(spaces[0].id, "primary-A")
        XCTAssertEqual(spaces[2].id, "UUID-3")
    }

    func testSkipsUnknownSpaceTypes() {
        let displays: [[String: Any]] = [[
            "Display Identifier": "Main",
            "Spaces": [space(1), space(2, type: 2), space(3)]
        ]]
        let spaces = SpaceLayout.parse(displays)
        XCTAssertEqual(spaces.map(\.managedID), [1, 3])
        XCTAssertEqual(spaces.map(\.position), [0, 1])
    }

    func testFullScreenSpaceTakesItsAppName() {
        let fullScreen: [String: Any] = [
            "ManagedSpaceID": 5, "type": 4, "uuid": "F",
            "TileLayoutManager": ["TileSpaces": [["appName": "Safari"], ["appName": "Notes"]]]
        ]
        let spaces = SpaceLayout.parse([["Spaces": [fullScreen]]])
        XCTAssertEqual(spaces.first?.defaultName, "Safari · Notes")
    }
}

final class SettingsTests: XCTestCase {
    private let desktop = DesktopSpace(id: "X", managedID: 1, displayID: "Main", kind: .desktop,
                                       position: 1, number: 2, ownerName: nil, isCurrent: false)

    func testNamesFallBackToDefault() {
        var settings = AppSettings()
        XCTAssertEqual(settings.name(for: desktop), "Desktop 2")
        settings.setName("  Work  ", for: desktop)
        XCTAssertEqual(settings.name(for: desktop), "Work")
        settings.setName("", for: desktop)
        XCTAssertNil(settings.names["X"])
        settings.setName("Desktop 2", for: desktop)
        XCTAssertNil(settings.names["X"])
    }

    func testOldSettingsStillDecode() throws {
        let json = #"{"hangStyle":"bunting","names":{"X":"Music"},"unknown":1}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.hangStyle, .bunting)
        XCTAssertEqual(settings.sway, .gentle)
        XCTAssertEqual(settings.name(for: desktop), "Music")
    }

    func testUnknownStyleFallsBack() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hangStyle":"balloons"}"#.utf8))
        XCTAssertEqual(settings.hangStyle, .clothesline)
    }
}

final class ShortcutTests: XCTestCase {
    func testSymbolicHotkeys() {
        let table: [String: Any] = [
            "118": ["enabled": true, "value": ["parameters": [49, 18, 262_144], "type": "standard"]],
            "119": ["enabled": false, "value": ["parameters": [50, 19, 262_144], "type": "standard"]],
            "79": ["enabled": false]
        ]
        XCTAssertEqual(SymbolicHotkeys.desktop(1, in: table), KeyShortcut(keyCode: 18, flags: .maskControl))
        XCTAssertNil(SymbolicHotkeys.desktop(2, in: table))
        XCTAssertNil(SymbolicHotkeys.desktop(3, in: table))
        XCTAssertNil(SymbolicHotkeys.move(right: false, in: table))
        XCTAssertEqual(SymbolicHotkeys.move(right: true, in: table)?.keyCode, 124)
    }

    /// macOS often stores only `enabled = 1` for a shortcut left on its
    /// default keys.
    func testEnabledWithoutKeysUsesTheDefault() {
        let table: [String: Any] = ["79": ["enabled": 1], "81": ["enabled": 1], "120": ["enabled": 1]]
        XCTAssertEqual(SymbolicHotkeys.move(right: false, in: table)?.keyCode, 123)
        XCTAssertEqual(SymbolicHotkeys.move(right: true, in: table)?.keyCode, 124)
        XCTAssertEqual(SymbolicHotkeys.desktop(3, in: table), KeyShortcut(keyCode: 20, flags: .maskControl))
    }

    @MainActor
    func testHotkeyParsing() {
        XCTAssertEqual(HotkeyService.parse("⌃⌥D")?.keyCode, 2)
        XCTAssertEqual(HotkeyService.parse("ctrl+option+R")?.keyCode, 15)
        XCTAssertNil(HotkeyService.parse("D"))
        XCTAssertNil(HotkeyService.parse("⌃⌥"))
    }
}

final class LayoutTests: XCTestCase {
    func testCardsShrinkOnlyWhenTheyDoNotFit() {
        XCTAssertEqual(LineLayout.scale(count: 4, width: 1440), 1)
        XCTAssertLessThan(LineLayout.scale(count: 16, width: 1440), 1)
        let xs = (0..<5).map { LineLayout.x(index: $0, count: 5, width: 1000) }
        XCTAssertEqual(xs[2], 500, accuracy: 0.01)
        XCTAssertGreaterThan(xs.first ?? 0, 0)
        XCTAssertLessThan(xs.last ?? 0, 1000)
    }

    func testTiltIsStable() {
        XCTAssertEqual(HangingDesktop.tilt(for: "abc"), HangingDesktop.tilt(for: "abc"))
        XCTAssertTrue((-2.5...2.5).contains(HangingDesktop.tilt(for: "some-uuid")))
    }

    func testEveryHangerFitsThePanel() {
        for style in HangStyle.allCases {
            for index in 0..<5 {
                let hanger = LineLayout.hanger(style, index: index)
                let cardTop = LineLayout.hangY(style, x: 720, width: 1440) + hanger.length
                let cardHeight = LineLayout.photoSize(aspect: 16 / 10).height + LineLayout.captionHeight + 14
                XCTAssertLessThan(cardTop + cardHeight, LineLayout.panelHeight - 10, "\(style) \(index)")
            }
        }
    }

    func testReadsLiveSpaces() {
        // Runs against the real window server; just prints what it sees.
        let spaces = SpaceService.read()
        print("Live shortcuts: left", SymbolicHotkeys.move(right: false) as Any, "right", SymbolicHotkeys.move(right: true) as Any,
              "desktop 1", SymbolicHotkeys.desktop(1) as Any)
        print("Live spaces:", spaces.map { "\($0.displayID.prefix(8)) #\($0.number.map(String.init) ?? "fs") current=\($0.isCurrent)" })
    }
}
