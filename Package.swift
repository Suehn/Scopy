// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScopyKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ScopyKit", targets: ["ScopyKit"]),
        .library(name: "ScopyUISupport", targets: ["ScopyUISupport"]),
        .executable(name: "ScopyBench", targets: ["ScopyBench"])
    ],
    targets: [
        .target(
            name: "ScopyKit",
            path: "Scopy",
            exclude: [
                "Info.plist",
                "Scopy.entitlements",
                "main.swift",
                "ScopyApp.swift",
                "AppDelegate.swift",
                "FloatingPanel.swift",
                "Design",
                "Observables",
                "Presentation",
                "Views"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "ScopyUISupport",
            path: "ScopyUISupport"
        ),
        .executableTarget(
            name: "ScopyBench",
            dependencies: ["ScopyKit"],
            path: "Tools/ScopyBench",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
