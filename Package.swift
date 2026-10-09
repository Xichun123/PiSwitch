// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiSwitch",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(name: "PiSwitchCore", dependencies: ["Yams"]),
        .executableTarget(name: "PiSwitch", dependencies: ["PiSwitchCore"]),
        .testTarget(name: "PiSwitchCoreTests", dependencies: ["PiSwitchCore"]),
    ],
    swiftLanguageModes: [.v5]
)
