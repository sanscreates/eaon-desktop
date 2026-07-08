// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Eaon-desktop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Eaon-desktop", targets: ["Eaon-desktop"])
    ],
    targets: [
        .executableTarget(
            name: "Eaon-desktop",
            path: "Eaon-desktop",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
