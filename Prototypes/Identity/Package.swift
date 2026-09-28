// swift-tools-version: 6.2
// THROWAWAY design prototype (emil-prototype): app identity directions. Imported by nothing; delete after the decision.
import PackageDescription

let package = Package(
    name: "IdentityProto",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../../Packages/CareMyMacKit")],
    targets: [
        .executableTarget(
            name: "IdentityProto",
            dependencies: [
                .product(name: "CareMyMacKit", package: "CareMyMacKit"),
                .product(name: "CareMyMacUI", package: "CareMyMacKit"),
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
