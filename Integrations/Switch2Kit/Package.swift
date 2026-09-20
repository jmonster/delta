// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeltaSwitch2Input",
    products: [.library(name: "DeltaSwitch2Input", targets: ["DeltaSwitch2Input"])],
    targets: [
        .target(name: "DeltaSwitch2Input"),
        .testTarget(name: "DeltaSwitch2InputTests", dependencies: ["DeltaSwitch2Input"])
    ]
)
