import AppKit

@MainActor
final class WorkspaceSessionService {
    let desktops: DesktopsViewModel
    private(set) var failedSession = WorkspaceSession()
    var selections: [String: WindowSelection] = [:]
    private let matchAttempts: Int
    private var completedWindows = Set<String>()
    private var savedAppCounts: [String: Int] = [:]
    init(desktops: DesktopsViewModel, matchAttempts: Int = 12) { self.desktops = desktops; self.matchAttempts = max(1, matchAttempts) }

    func capture(launchItems: [SessionLaunchItem]) async throws -> WorkspaceSession {
        desktops.reload()
        let windows = try await desktops.windowsForMove()
        var session = WorkspaceSession(launchItems: launchItems)
        session.windows = windows.compactMap { window in
            guard let bundleID = window.bundleID,
                  let space = desktops.spaces.first(where: { $0.managedID == window.selection.sourceSpaceID }) else { return nil }
            guard !window.isMinimized else { return nil }
            let bounds = DesktopsViewModel.screen(for: space.displayID).map(Self.accessibilityBounds)
            let normalized = window.frame.flatMap { frame in bounds.flatMap { AdaptiveWindowFrame.normalize(frame, in: $0) } }
            return SavedWindowPlacement(bundleID: bundleID, title: window.title, desktopID: space.id, frame: window.frame,
                                        normalizedFrame: normalized, displayIdentity: space.displayID)
        }
        for bundleID in Set(session.windows.map(\.bundleID)).sorted() {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  !session.launchItems.contains(where: { $0.address == url.absoluteString }) else { continue }
            session.launchItems.append(SessionLaunchItem(address: url.absoluteString, name: url.deletingPathExtension().lastPathComponent))
        }
        return session
    }

    func restore(_ session: WorkspaceSession, retrying: Bool = false) async -> [String] {
        if !retrying {
            completedWindows = []
            savedAppCounts = Dictionary(grouping: session.windows, by: \.bundleID).mapValues(\.count)
        }
        var errors: [String] = []
        failedSession = WorkspaceSession()
        for (index, item) in session.launchItems.enumerated() {
            guard !Task.isCancelled else {
                failedSession.launchItems += session.launchItems.dropFirst(index)
                failedSession.windows = session.windows
                return errors + [String(localized: "Session restoration was cancelled.")]
            }
            guard let url = item.url else { errors.append(item.name + ": " + String(localized: "Invalid address.")); failedSession.launchItems.append(item); continue }
            do {
                if url.isFileURL, url.pathExtension.lowercased() == "app" {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                } else if !NSWorkspace.shared.open(url) {
                    throw WorkspaceFeatureError(message: String(localized: "Could not open this item."))
                }
            } catch { errors.append(item.name + ": " + error.localizedDescription); failedSession.launchItems.append(item) }
        }
        guard !session.windows.isEmpty else { return errors }
        var pending = session.windows
        var used = Set<CGWindowID>()
        // Apps may need a moment to restore their documents. Never invent a match
        // between several windows of one app, and never use a window twice.
        for attempt in 0..<matchAttempts {
            guard !Task.isCancelled else { failedSession.windows += pending; return errors + [String(localized: "Session restoration was cancelled.")] }
            do {
                desktops.reload()
                let windows = try await desktops.windowsForMove()
                var remaining: [SavedWindowPlacement] = []
                for saved in pending {
                    guard let target = desktops.spaces.first(where: { $0.id == saved.desktopID && $0.kind == .desktop }) else {
                        errors.append(saved.title + ": " + String(localized: "Desktop unavailable")); failedSession.windows.append(saved); continue
                    }
                    let candidates = windows.filter { !used.contains($0.id) && !$0.isMinimized && !completedWindows.contains("\($0.selection.processID):\($0.id)") }
                    let allowFallback = savedAppCounts[saved.bundleID] == 1
                    let selected: WindowCandidate?
                    if let explicit = selections[saved.id] { selected = candidates.first { $0.id == explicit.id && $0.selection.processID == explicit.processID && $0.bundleID == saved.bundleID } }
                    else { selected = Self.match(saved, in: candidates, allowSingleWindowFallback: allowFallback) }
                    guard let window = selected else {
                        remaining.append(saved); continue
                    }
                    used.insert(window.id)
                    do {
                        let bounds = DesktopsViewModel.screen(for: target.displayID).map(Self.accessibilityBounds)
                        // A saved Space UUID is authoritative. Never guess a new Space
                        // from monitor order when its original display is missing.
                        if let identity = saved.displayIdentity, identity != target.displayID {
                            throw WorkspaceFeatureError(message: String(localized: "The saved display changed. Edit the preset and confirm the target desktop."))
                        }
                        let frame = AdaptiveWindowFrame.resolve(saved.normalizedFrame, absolute: saved.frame, in: bounds).map { Self.clamp($0, to: bounds) }
                        try await desktops.placeWindow(window.selection, on: target, frame: frame)
                        completedWindows.insert("\(window.selection.processID):\(window.id)")
                        desktops.journal.record("Restore Session", item: "Window #\(window.id)")
                    } catch {
                        errors.append(saved.title + ": " + error.localizedDescription)
                        failedSession.windows.append(saved)
                        desktops.journal.record("Restore Session", item: "Window #\(window.id)", error: error)
                    }
                }
                pending = remaining
                if pending.isEmpty { break }
            } catch { errors.append(error.localizedDescription); failedSession.windows += pending; return errors }
            if attempt < matchAttempts - 1 { try? await Task.sleep(for: .milliseconds(500)) }
        }
        failedSession.windows += pending
        errors += pending.map { $0.title + ": " + String(localized: "No unique matching window. Open the document and apply the preset again.") }
        return errors
    }

    static func match(_ saved: SavedWindowPlacement, in windows: [WindowCandidate], allowSingleWindowFallback: Bool) -> WindowCandidate? {
        let app = windows.filter { $0.bundleID == saved.bundleID }
        let exact = app.filter { $0.title == saved.title }
        if exact.count == 1 { return exact[0] }
        return exact.isEmpty && allowSingleWindowFallback && app.count == 1 ? app[0] : nil
    }

    static func accessibilityBounds(_ screen: NSScreen) -> CGRect {
        let frame = screen.visibleFrame
        let top = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }

    static func clamp(_ frame: CGRect, to bounds: CGRect?) -> CGRect {
        guard let bounds else { return frame }
        let width = min(max(frame.width, 100), bounds.width)
        let height = min(max(frame.height, 80), bounds.height)
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }
}
