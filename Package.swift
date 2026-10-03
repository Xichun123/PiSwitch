// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiSwitch",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "PiSwitchCore"),
        .executableTarget(name: "PiSwitch", dependencies: ["PiSwitchCore"]),
        .testTarget(name: "PiSwitchCoreTests", dependencies: ["PiSwitchCore"]),
    ],
    swiftLanguageModes: [.v5]
)
