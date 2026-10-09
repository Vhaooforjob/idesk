import AppKit
import Combine
import SwiftUI
import XCTest
@testable import iDesk

/// Renders the line in every hanging style, for docs and for eyeballing
/// changes. Runs only when IDESK_SHOTS_DIR is set:
///
///     IDESK_SHOTS_DIR=/tmp/idesk-shots swift test --filter StyleShotsTests
@MainActor
final class StyleShotsTests: XCTestCase {
    func testRenderEveryStyle() throws {
        guard let folder = ProcessInfo.processInfo.environment["IDESK_SHOTS_DIR"] else {
            throw XCTSkip("Set IDESK_SHOTS_DIR to render the styles.")
        }
        let output = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let particles: [HangStyle: ParticleStyle] = [.clothesline: .none, .strings: .petals, .frames: .none,
                                                     .bunting: .sparkles, .fairyLights: .snow, .rail: .leaves]
        for style in HangStyle.allCases {
            var settings = AppSettings()
            settings.hangStyle = style
            settings.sway = .still
            settings.particles = particles[style] ?? .none
            let line = DesktopLineViewModel(preview: SettingsViewModel.sampleDesktops, settings: Just(settings).eraseToAnyPublisher())

            let view = ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(red: 0.27, green: 0.35, blue: 0.62), Color(red: 0.62, green: 0.42, blue: 0.62), Color(red: 0.95, green: 0.62, blue: 0.48)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                DesktopLineView(viewModel: line, isInteractive: false)
                    .frame(width: 900, height: LineLayout.panelHeight)
            }
            .frame(width: 900, height: LineLayout.panelHeight)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("line-\(style.rawValue).png"))
        }
    }
}
