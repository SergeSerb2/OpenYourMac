// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenYourMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenYourMac",
            path: "Sources/OpenYourMac",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
