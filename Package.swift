// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iDesk", targets: ["iDesk"])
    ],
    targets: [
        .executableTarget(
            name: "iDesk",
            path: "Sources/iDesk",
            exclude: ["Resources/Info.plist", "Resources/iDesk.entitlements", "Resources/Localizable.xcstrings"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "iDeskTests",
            dependencies: ["iDesk"],
            path: "Tests/iDeskTests"
        )
    ]
)
