import Foundation

/// One Space as Mission Control knows it: a desktop or a full screen app.
struct DesktopSpace: Identifiable, Hashable {
    enum Kind: Hashable { case desktop, fullScreen }

    /// The Space's UUID. It survives restarts, so names are keyed by it.
    let id: String
    let managedID: Int
    /// The display the Space belongs to, or "Main" when every display
    /// shares the same Spaces.
    let displayID: String
    let kind: Kind
    /// Position among the display's Spaces, full screen apps included: the
    /// order ⌃← and ⌃→ walk through.
    let position: Int
    /// Mission Control's "Desktop N", counted across displays. Desktops only.
    let number: Int?
    /// The app that owns a full screen Space, when macOS says.
    let ownerName: String?
    var isCurrent: Bool

    var defaultName: String {
        switch kind {
        case .desktop: String(localized: "Desktop \(number ?? position + 1)")
        case .fullScreen: ownerName ?? String(localized: "Full Screen")
        }
    }
}

/// Reads the window server's description of Spaces, as returned by
/// `CGSCopyManagedDisplaySpaces`. Kept free of the private call so it can be
/// tested with plain dictionaries.
enum SpaceLayout {
    static let desktopType = 0
    static let fullScreenType = 4

    static func parse(_ displays: [[String: Any]]) -> [DesktopSpace] {
        var result: [DesktopSpace] = []
        var number = 0
        for display in displays {
            let displayID = display["Display Identifier"] as? String ?? "Main"
            let current = (display["Current Space"] as? [String: Any]).flatMap(managedID(of:))
            var position = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let managed = managedID(of: space) else { continue }
                let type = space["type"] as? Int ?? desktopType
                // Older systems listed a Dashboard Space too; it is not a desktop.
                guard type == desktopType || type == fullScreenType else { continue }
                let isDesktop = type == desktopType
                if isDesktop { number += 1 }
                result.append(DesktopSpace(
                    id: identifier(of: space, managed: managed, displayID: displayID, position: position),
                    managedID: managed,
                    displayID: displayID,
                    kind: isDesktop ? .desktop : .fullScreen,
                    position: position,
                    number: isDesktop ? number : nil,
                    ownerName: isDesktop ? nil : ownerName(of: space),
                    isCurrent: managed == current
                ))
                position += 1
            }
        }
        return result
    }

    private static func managedID(of space: [String: Any]) -> Int? {
        (space["ManagedSpaceID"] as? Int) ?? (space["id64"] as? Int)
    }

    /// A display's original desktop can come without a UUID. It is always
    /// the first one there, so it is keyed by its display instead.
    private static func identifier(of space: [String: Any], managed: Int, displayID: String, position: Int) -> String {
        if let uuid = space["uuid"] as? String, !uuid.isEmpty { return uuid }
        return position == 0 ? "primary-\(displayID)" : "space-\(managed)"
    }

    private static func ownerName(of space: [String: Any]) -> String? {
        if let tiles = (space["TileLayoutManager"] as? [String: Any])?["TileSpaces"] as? [[String: Any]] {
            let names = tiles.compactMap { $0["appName"] as? String }
            if !names.isEmpty { return names.joined(separator: " · ") }
        }
        return space["appName"] as? String
    }
}
