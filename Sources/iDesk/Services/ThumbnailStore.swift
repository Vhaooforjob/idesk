import AppKit
import Combine
import ImageIO
import os
import ScreenCaptureKit

private let log = Logger(subsystem: "dev.idesk.app", category: "Thumbnails")

/// A small picture of every desktop. macOS cannot show a Space you are not
/// on, so each one is photographed while you are there and kept on disk
/// for the next launch. Without Screen Recording access the desktop's
/// wallpaper stands in.
@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]

    @Published private(set) var dates: [String: Date] = [:]
    private(set) var storesOnDisk: Bool
    private var generation = 0
    private var privateIDs: Set<String> = []
    /// Encoding and writing a picture takes a moment, so it happens here,
    /// one file at a time and in order, instead of on the main thread.
    private let writer = DispatchQueue(label: "dev.idesk.thumbnail-writer", qos: .utility)

    static let width = 480
    private let folder: URL
    private struct CaptureKey: Hashable {
        let spaceID: String
        let displayID: CGDirectDisplayID
    }
    private var capturingDisplays: Set<CGDirectDisplayID> = []
    private var capturedAt: [CaptureKey: Date] = [:]
    private let captureImage: (CGDirectDisplayID) async throws -> CGImage?
    private let canCapture: () -> Bool
    private let now: () -> Date
    private static let minimumCaptureInterval: TimeInterval = 5

    nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.idesk.app/Thumbnails", isDirectory: true)
    }

    init(folder: URL = ThumbnailStore.defaultFolder, storesOnDisk: Bool = true,
         canCapture: @escaping () -> Bool = { PermissionService.canCapturePreviews },
         now: @escaping () -> Date = Date.init,
         captureImage: @escaping (CGDirectDisplayID) async throws -> CGImage? = { try await ThumbnailStore.screenshot(on: $0) }) {
        self.folder = folder
        self.storesOnDisk = storesOnDisk
        self.canCapture = canCapture
        self.now = now
        self.captureImage = captureImage
        if storesOnDisk { loadSaved() }
    }

    /// Photographs the screen as it is now. `stillThere` is asked once the
    /// picture is ready, so a picture taken during a switch is dropped.
    func capture(_ space: DesktopSpace, on screen: NSScreen, force: Bool = false, stillThere: @escaping () -> Bool) {
        guard !privateIDs.contains(space.id) else { return }
        let displayID = screen.displayID
        let key = CaptureKey(spaceID: space.id, displayID: displayID)
        guard !capturingDisplays.contains(displayID),
              force || (capturedAt[key].map({ now().timeIntervalSince($0) >= Self.minimumCaptureInterval }) ?? true) else { return }
        guard canCapture() else {
            if images[space.id] == nil { useWallpaper(for: space, on: screen) }
            return
        }
        capturingDisplays.insert(displayID)
        let requestGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            defer { self.capturingDisplays.remove(displayID) }
            do {
                guard stillThere(), let image = try await self.captureImage(displayID), stillThere(), requestGeneration == self.generation else { return }
                self.dates[space.id] = self.now()
                self.store(image, for: space.id)
                self.capturedAt[key] = self.now()
            } catch {
                log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Invalidate in-flight captures before removing files, so Clear cannot be undone by a late result.
    func setPrivateSpaces(_ ids: Set<String>) throws {
        privateIDs = ids
        generation += 1
        images = images.filter { !ids.contains($0.key) }
        dates = dates.filter { !ids.contains($0.key) }
        capturedAt = capturedAt.filter { !ids.contains($0.key.spaceID) }
        let files = ids.map { url(for: $0) }
        try writer.sync {
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    func clear() throws {
        generation += 1
        images = [:]
        dates = [:]
        capturedAt = [:]
        try removeSaved()
    }

    func setStoresOnDisk(_ enabled: Bool) throws {
        storesOnDisk = enabled
        if !enabled { try removeSaved() }
    }

    /// Waits until every picture handed over so far is on disk.
    func flushWrites() {
        writer.sync {}
    }

    /// Runs behind any write still queued, so a picture cannot reappear
    /// after it was removed.
    private func removeSaved() throws {
        let folder = folder
        try writer.sync {
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where file.pathExtension == "jpg" {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func screenshot(on displayID: CGDirectDisplayID) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        // The line and the banner are iDesk's own windows; leave them out.
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Self.width
        configuration.height = max(1, Self.width * display.height / max(1, display.width))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    func forget(keeping ids: Set<String>) {
        generation += 1
        dates = dates.filter { ids.contains($0.key) }
        capturedAt = capturedAt.filter { ids.contains($0.key.spaceID) }
        for id in images.keys where !ids.contains(id) {
            images[id] = nil
            let file = url(for: id)
            writer.async { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func useWallpaper(for space: DesktopSpace, on screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.width,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return }
        images[space.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func store(_ image: CGImage, for id: String) {
        images[id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard storesOnDisk else { return }
        let folder = folder
        let file = url(for: id)
        writer.async {
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                log.error("Could not save thumbnail: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadSaved() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jpg" {
            if let image = NSImage(contentsOf: file) {
                let id = file.deletingPathExtension().lastPathComponent
                images[id] = image
                dates[id] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
        }
    }

    private func url(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent(safe).appendingPathExtension("jpg")
    }
}
