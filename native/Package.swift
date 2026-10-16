// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoamPrint",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RoamPrint", targets: ["RoamPrintApp"]),
        .executable(name: "roamprint-service", targets: ["RoamPrintService"]),
        .library(name: "RoamPrintCore", targets: ["RoamPrintCore"])
    ],
    targets: [
        .target(name: "LegacyCrypto", publicHeadersPath: "include"),
        .target(name: "RoamPrintCore", dependencies: ["LegacyCrypto"]),
        .executableTarget(name: "RoamPrintApp", dependencies: ["RoamPrintCore"]),
        .executableTarget(name: "RoamPrintService", dependencies: ["RoamPrintCore"]),
        .testTarget(name: "RoamPrintCoreTests", dependencies: ["RoamPrintCore"])
    ],
    swiftLanguageModes: [.v5]
)
