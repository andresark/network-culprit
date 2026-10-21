// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NetworkCulprit",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "NetworkCulprit", targets: ["NetworkCulprit"])],
    targets: [
        .executableTarget(name: "NetworkCulprit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "NetworkCulpritTests", dependencies: ["NetworkCulprit"])
    ],
    swiftLanguageModes: [.v6]
)
