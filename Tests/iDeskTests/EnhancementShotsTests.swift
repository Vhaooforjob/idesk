import AppKit
import SwiftUI
import XCTest
@testable import iDesk

/// Opt-in UI render checks with synthetic data; never captures the user's desktop.
@MainActor
final class EnhancementShotsTests: XCTestCase {
    func testRenderNewPanels() async throws {
        guard let path = ProcessInfo.processInfo.environment["IDESK_SHOTS_DIR"] else {
            throw XCTSkip("Set IDESK_SHOTS_DIR to inspect the new panels.")
        }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = SettingsStore(fileURL: folder.appendingPathComponent("fixture-settings.json"))
        let spaces = (1...3).map {
            DesktopSpace(id: "S\($0)", managedID: $0, displayID: "A", kind: .desktop,
                         position: $0 - 1, number: $0, ownerName: nil, isCurrent: $0 == 1)
        }
        let names = ["Lập trình", "Meeting", "Personal"]
        let search = DesktopSearchViewModel(read: {
            spaces.enumerated().map {
                .init(space: $0.element, name: names[$0.offset], displayName: "Display 1",
                      appearance: DesktopAppearance(color: [.blue, .orange, .purple][$0.offset],
                                                    symbol: ["chevron.left.forwardslash.chevron.right", "video", "house"][$0.offset]))
            }
        })
        search.open()
        try render(DesktopSearchView(model: search, submit: {}, cancel: {}), name: "search", size: NSSize(width: 500, height: 400), folder: folder)
        let picker = WindowPickerViewModel(readWindows: {
            [WindowCandidate(selection: WindowSelection(id: 1, processID: 123, sourceSpaceID: 1),
                             appName: "Editor", title: "iDesk — feature work")]
        }, readDestinations: { _ in spaces.dropFirst().map { WindowDestination(space: $0, name: names[$0.position]) } })
        await picker.load()
        try render(WindowPickerView(viewModel: picker, settingsStore: store, submit: {}, cancel: {}, refresh: {}, openAccessibility: {}),
                   name: "move", size: NSSize(width: 720, height: 480), folder: folder)
        let displays = DisplaysViewModel(service: FakeDisplayService([
            DisplayInfo(id: 1, name: "Main", isBuiltin: true, isEnabled: true)
        ]), dialogs: FakeDialogs())
        let presets = PresetsViewModel(store: store, displays: displays)
        try render(PresetsTab(viewModel: presets, displays: displays), name: "presets", size: NSSize(width: 720, height: 560), folder: folder)
        let service = SpaceService(read: { spaces })
        service.reload()
        let desktops = DesktopsViewModel(spaceService: service, thumbnailStore: ThumbnailStore(folder: folder),
            settingsStore: store, switcher: SpaceSwitcher(spaces: service), desktopManager: FakeDesktopManager(), dialogs: FakeDialogs())
        let settings = SettingsViewModel(settingsStore: store, desktops: desktops, screens: displays)
        try render(SettingsView(viewModel: settings), name: "settings", size: NSSize(width: 760, height: 600), folder: folder)
    }

    private func render<V: View>(_ view: V, name: String, size: NSSize, folder: URL) throws {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(data.count, 1000)
    }
}
