// swift-tools-version: 6.2
import PackageDescription

// The upstream manifest currently declares macOS only. This iOS host wrapper
// builds the exact pinned, unmodified engine sources with an explicit iOS floor
// for Synchronization.Mutex. No C ABI, desktop application or SDL is included.
let package = Package(
    name: "DeltaSwitch2Engine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Switch2Kit", targets: ["Switch2Kit"]),
        .library(name: "DeltaSwitch2Bridge", targets: ["DeltaSwitch2Bridge"])
    ],
    dependencies: [.package(path: "..")],
    targets: [
        .target(name: "Switch2Kit", path: "Vendor/Switch2Kit/Sources/Switch2Kit",
                swiftSettings: [.swiftLanguageMode(.v6)],
                linkerSettings: [.linkedFramework("CoreBluetooth")]),
        .target(name: "DeltaSwitch2Bridge", dependencies: ["Switch2Kit",
                .product(name: "DeltaSwitch2Input", package: "switch2kit")]),
        .testTarget(name: "DeltaSwitch2BridgeTests", dependencies: ["DeltaSwitch2Bridge", "Switch2Kit"])
    ]
)
