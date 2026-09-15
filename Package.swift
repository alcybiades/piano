// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadenza",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cadenza", targets: ["Cadenza"])],
    targets: [
        .target(name: "PianoCore"),
        .executableTarget(name: "Cadenza", dependencies: ["PianoCore"]),
        .testTarget(name: "PianoCoreTests", dependencies: ["PianoCore"])
    ],
    swiftLanguageModes: [.v5]
)
