import AppKit
import ApplicationServices

/// Captured before a menu opens; never replaced with whichever window happens
/// to be focused after the user chooses a destination.
struct WindowSelection: Equatable {
    let id: CGWindowID
    let processID: pid_t
    let sourceSpaceID: Int
}

struct WindowListEntry {
    let id: CGWindowID
    let processID: pid_t
    let appName: String
    let title: String
    var icon: NSImage? = nil
}

struct WindowCandidate: Identifiable {
    let selection: WindowSelection
    let appName: String
    let title: String
    var icon: NSImage? = nil
    var id: CGWindowID { selection.id }
}

@MainActor
protocol WindowMoving: AnyObject {
    func availableWindows() async throws -> [WindowCandidate]
    func captureFocusedWindow() throws -> WindowSelection
    func move(_ window: WindowSelection, to destination: DesktopSpace) async throws
    func focus(_ window: WindowSelection) throws
}

enum WindowMoveError: LocalizedError, Equatable {
    case needsPermission, noWindow, unsupportedWindow, unavailable, staleWindow, invalidDestination, refused, followFailed

    var errorDescription: String? {
        switch self {
        case .needsPermission: String(localized: "Allow iDesk in System Settings → Privacy & Security → Accessibility to move windows.")
        case .noWindow: String(localized: "Select an application window first, then try again.")
        case .unsupportedWindow: String(localized: "Use a regular window on one desktop. Exit full screen or Split View, and unpin windows assigned to all desktops.")
        case .unavailable: String(localized: "Moving windows is not available on this version of macOS.")
        case .staleWindow: String(localized: "The selected window was closed or moved. Select it again and retry.")
        case .invalidDestination: String(localized: "Choose another desktop on the same display as the selected window.")
        case .refused: String(localized: "macOS did not move the window. You can move it manually in Mission Control.")
        case .followFailed: String(localized: "The window moved, but iDesk could not switch to its desktop. Open that desktop from Mission Control.")
        }
    }
}

/// Injectable boundary: tests never move real application windows.
@MainActor
protocol WindowMoveSystem: AnyObject {
    func windows() async throws -> [WindowListEntry]
    func focusedWindow() throws -> (id: CGWindowID, processID: pid_t)
    func validate(_ window: WindowSelection) throws
    func spaces(for window: CGWindowID) throws -> [Int]
    func move(_ window: CGWindowID, to space: Int) throws
    func focus(_ window: WindowSelection) throws
}

@MainActor
final class WindowMoveService: WindowMoving {
    private let system: WindowMoveSystem
    private let readSpaces: () -> [DesktopSpace]

    convenience init() {
        self.init(system: SkyLightWindowSystem(), readSpaces: SpaceService.read)
    }

    init(system: WindowMoveSystem, readSpaces: @escaping () -> [DesktopSpace]) {
        self.system = system
        self.readSpaces = readSpaces
    }

    func captureFocusedWindow() throws -> WindowSelection {
        let window = try system.focusedWindow()
        let memberships = try system.spaces(for: window.id)
        guard memberships.count == 1,
              let source = readSpaces().first(where: { $0.managedID == memberships[0] }),
              source.kind == .desktop, source.isCurrent else { throw WindowMoveError.unsupportedWindow }
        return WindowSelection(id: window.id, processID: window.processID, sourceSpaceID: source.managedID)
    }

    func availableWindows() async throws -> [WindowCandidate] {
        let windows = try await system.windows()
        let spaces = readSpaces()
        var seen = Set<CGWindowID>()
        return windows.compactMap { window in
            guard seen.insert(window.id).inserted,
                  let memberships = try? system.spaces(for: window.id), memberships.count == 1,
                  let source = spaces.first(where: { $0.managedID == memberships[0] }),
                  source.kind == .desktop, source.isCurrent else { return nil }
            return WindowCandidate(
                selection: WindowSelection(id: window.id, processID: window.processID, sourceSpaceID: source.managedID),
                appName: window.appName, title: window.title, icon: window.icon)
        }
    }

    func move(_ window: WindowSelection, to destination: DesktopSpace) async throws {
        try system.validate(window)
        let spaces = readSpaces()
        guard let source = spaces.first(where: { $0.managedID == window.sourceSpaceID }),
              source.kind == .desktop,
              try system.spaces(for: window.id) == [source.managedID] else { throw WindowMoveError.staleWindow }
        guard let target = spaces.first(where: { $0.id == destination.id && $0.managedID == destination.managedID }),
              target.kind == .desktop, target.displayID == source.displayID,
              target.managedID != source.managedID else { throw WindowMoveError.invalidDestination }
        try Task.checkCancellation()
        try system.move(window.id, to: target.managedID)
        // The private call may report success before the move lands, or do
        // nothing on an unsupported OS. Verify membership before following.
        for _ in 0..<20 {
            try system.validate(window)
            if try system.spaces(for: window.id) == [target.managedID] { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw WindowMoveError.refused
    }

    func focus(_ window: WindowSelection) throws { try system.focus(window) }
}

/// Private SkyLight entry points are resolved at runtime so a missing symbol
/// disables this operation instead of preventing iDesk from starting.
/// The 14.5+ compatibility-workspace route is documented by Hammerspoon:
/// https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/spaces/libspaces.m
@MainActor
private final class SkyLightWindowSystem: WindowMoveSystem {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias WindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindows = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias SetCompat = @convention(c) (Int32, UInt64, Int32) -> CGError
    private typealias SetWorkspace = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, Int32) -> CGError

    private let connection: MainConnection? = SkyLightWindowSystem.symbol("SLSMainConnectionID")
    private let windowID: WindowID? = SkyLightWindowSystem.symbol("_AXUIElementGetWindow")
    private let copySpaces: CopySpaces? = SkyLightWindowSystem.symbol("SLSCopySpacesForWindows")
    private let moveWindows: MoveWindows? = SkyLightWindowSystem.symbol("SLSMoveWindowsToManagedSpace")
    private let setCompat: SetCompat? = SkyLightWindowSystem.symbol("SLSSpaceSetCompatID")
    private let setWorkspace: SetWorkspace? = SkyLightWindowSystem.symbol("SLSSetWindowListWorkspace")

    private static func symbol<T>(_ name: String) -> T? {
        guard let address = dlsym(dlopen(nil, RTLD_NOW), name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func checkWindow(_ element: AXUIElement) throws {
        guard attribute(kAXSubroleAttribute, of: element) as? String == kAXStandardWindowSubrole,
              attribute("AXFullScreen", of: element) as? Bool != true,
              attribute(kAXMinimizedAttribute, of: element) as? Bool != true else {
            throw WindowMoveError.unsupportedWindow
        }
    }

    func focusedWindow() throws -> (id: CGWindowID, processID: pid_t) {
        guard AXIsProcessTrusted() else { throw WindowMoveError.needsPermission }
        guard let windowID else { throw WindowMoveError.unavailable }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw WindowMoveError.noWindow }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.5)
        guard let value = attribute(kAXFocusedWindowAttribute, of: application),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { throw WindowMoveError.noWindow }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        try checkWindow(element)
        var id: CGWindowID = 0
        guard windowID(element, &id) == .success, id != 0 else { throw WindowMoveError.noWindow }
        return (id, app.processIdentifier)
    }

    func windows() async throws -> [WindowListEntry] {
        guard AXIsProcessTrusted() else { throw WindowMoveError.needsPermission }
        guard let windowID, connection != nil, copySpaces != nil else { throw WindowMoveError.unavailable }
        // Window IDs/order need no image capture. Read titles via Accessibility,
        // so the picker does not require Screen Recording permission.
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let ids = visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let owners = Set(visible.compactMap { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value })
        var result: [WindowListEntry] = []
        for app in NSWorkspace.shared.runningApplications
            where owners.contains(app.processIdentifier) && !app.isHidden
                && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            try Task.checkCancellation()
            await Task.yield()
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.2)
            guard let windows = attribute(kAXWindowsAttribute, of: application) as? [AXUIElement] else { continue }
            for element in windows {
                var id: CGWindowID = 0
                guard windowID(element, &id) == .success, order[id] != nil,
                      (try? checkWindow(element)) != nil else { continue }
                let name = app.localizedName ?? String(localized: "Application")
                let title = (attribute(kAXTitleAttribute, of: element) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(WindowListEntry(id: id, processID: app.processIdentifier, appName: name,
                    title: title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled Window"), icon: app.icon))
            }
        }
        return result.sorted { order[$0.id, default: .max] < order[$1.id, default: .max] }
    }

    private func element(for window: WindowSelection) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw WindowMoveError.needsPermission }
        guard let windowID else { throw WindowMoveError.unavailable }
        let app = AXUIElementCreateApplication(window.processID)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let windows = attribute(kAXWindowsAttribute, of: app) as? [AXUIElement],
              let element = windows.first(where: {
                  var id: CGWindowID = 0
                  return windowID($0, &id) == .success && id == window.id
              }) else { throw WindowMoveError.staleWindow }
        try checkWindow(element)
        return element
    }

    func validate(_ window: WindowSelection) throws { _ = try element(for: window) }

    func spaces(for window: CGWindowID) throws -> [Int] {
        guard let connection, let copySpaces else { throw WindowMoveError.unavailable }
        guard let result = copySpaces(connection(), 0x7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue()
                as? [NSNumber] else { throw WindowMoveError.staleWindow }
        return result.map(\.intValue)
    }

    func move(_ window: CGWindowID, to space: Int) throws {
        guard let connection, space > 0 else { throw WindowMoveError.unavailable }
        let cid = connection()
        if #available(macOS 14.5, *) {
            guard let setCompat, let setWorkspace else { throw WindowMoveError.unavailable }
            // Temporary workspace identity; restored even when the move fails.
            let workspace: Int32 = 0x6944534B // iDSK
            guard setCompat(cid, UInt64(space), workspace) == .success else { throw WindowMoveError.refused }
            var id = window
            let result = setWorkspace(cid, &id, 1, workspace)
            let cleanup = setCompat(cid, UInt64(space), 0)
            guard result == .success, cleanup == .success else { throw WindowMoveError.refused }
        } else {
            guard let moveWindows else { throw WindowMoveError.unavailable }
            moveWindows(cid, [NSNumber(value: window)] as CFArray, UInt64(space))
        }
    }

    func focus(_ window: WindowSelection) throws {
        let element = try element(for: window)
        guard AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success,
              NSRunningApplication(processIdentifier: window.processID)?.activate(options: []) == true else {
            throw WindowMoveError.followFailed
        }
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
}
