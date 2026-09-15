// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Piano",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Piano", targets: ["Piano"])],
    targets: [
        .target(name: "PianoCore"),
        .executableTarget(name: "Piano", dependencies: ["PianoCore"]),
        .testTarget(name: "PianoCoreTests", dependencies: ["PianoCore"])
    ],
    swiftLanguageModes: [.v5]
)
