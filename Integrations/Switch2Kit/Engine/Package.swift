// swift-tools-version: 6.2
import PackageDescription

// prepare_engine.py stages Vendor/Switch2Kit/Sources/Switch2Kit without editing
// the dependency. Its only source change guards IOBluetooth's import and API,
// preserving the existing unknown-address path on iOS. Both native tests and
// the application build the same staged engine. No C ABI, dashboard or SDL.
let package = Package(
    name: "DeltaSwitch2Engine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Switch2Kit", targets: ["Switch2Kit"]),
        .library(name: "DeltaSwitch2Bridge", targets: ["DeltaSwitch2Bridge"])
    ],
    dependencies: [.package(path: "..")],
    targets: [
        .target(name: "Switch2Kit", path: "Generated/Switch2Kit",
                swiftSettings: [.swiftLanguageMode(.v6)],
                linkerSettings: [.linkedFramework("CoreBluetooth")]),
        .target(name: "DeltaSwitch2Bridge", dependencies: ["Switch2Kit",
                .product(name: "DeltaSwitch2Input", package: "switch2kit")]),
        .testTarget(name: "DeltaSwitch2BridgeTests", dependencies: ["DeltaSwitch2Bridge", "Switch2Kit"])
    ]
)
