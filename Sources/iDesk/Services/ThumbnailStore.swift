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

    static let width = 480
    private let folder: URL
    private var isCapturing = false

    nonisolated static var defaultFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.idesk.app/Thumbnails", isDirectory: true)
    }

    init(folder: URL = ThumbnailStore.defaultFolder) {
        self.folder = folder
        loadSaved()
    }

    /// Photographs the screen as it is now. `stillThere` is asked once the
    /// picture is ready, so a picture taken during a switch is dropped.
    func capture(_ space: DesktopSpace, on screen: NSScreen, stillThere: @escaping () -> Bool) {
        guard !isCapturing else { return }
        guard PermissionService.canCapturePreviews else {
            if images[space.id] == nil { useWallpaper(for: space, on: screen) }
            return
        }
        isCapturing = true
        let displayID = screen.displayID
        Task { [weak self] in
            defer { self?.isCapturing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
                // The line and the banner are iDesk's own windows; leave them out.
                let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = Self.width
                configuration.height = max(1, Self.width * display.height / max(1, display.width))
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard let self, stillThere() else { return }
                self.store(image, for: space.id)
            } catch {
                log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func forget(keeping ids: Set<String>) {
        for id in images.keys where !ids.contains(id) {
            images[id] = nil
            try? FileManager.default.removeItem(at: url(for: id))
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
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url(for: id), options: .atomic)
        } catch {
            log.error("Could not save thumbnail: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadSaved() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "jpg" {
            if let image = NSImage(contentsOf: file) {
                images[file.deletingPathExtension().lastPathComponent] = image
            }
        }
    }

    private func url(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent(safe).appendingPathExtension("jpg")
    }
}
