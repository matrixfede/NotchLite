// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchLite",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NotchLite",
            path: "Sources/NotchLite",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("EventKit"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
