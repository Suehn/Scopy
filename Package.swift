// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Scopy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Scopy", targets: ["Scopy"])
    ],
    targets: [
        .executableTarget(
            name: "Scopy",
            path: "Scopy",
            resources: [
                .process("Info.plist")
            ]
        )
    ]
)
