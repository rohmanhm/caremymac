// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CareMyMacKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CareMyMacKit", targets: ["CareMyMacKit"]),
        .library(name: "CareMyMacUI", targets: ["CareMyMacUI"]),
    ],
    targets: [
        .target(
            name: "CareMyMacKit",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(name: "CareMyMacUI", dependencies: ["CareMyMacKit"]),
        .testTarget(name: "CareMyMacKitTests", dependencies: ["CareMyMacKit", "CareMyMacUI"]),
    ]
)
