// swift-tools-version: 6.0
import PackageDescription

// The FUSE headers live in Sources/CFuseT/include/fuse (from FUSE-T, LGPL).
// The library itself is only loaded at runtime (dlopen), so Zippy can launch
// without FUSE-T installed and tell the user what is missing.
let package = Package(
    name: "FuseMount",
    defaultLocalization: "en",   // messages: Sources/FuseMount/Resources/Localizable.xcstrings
    platforms: [.macOS("15.4")],
    products: [.library(name: "FuseMount", targets: ["FuseMount"])],
    dependencies: [.package(path: "../ArchiveCore")],
    targets: [
        .target(name: "CFuseT"),
        .target(
            name: "FuseMount",
            dependencies: ["CFuseT", .product(name: "ArchiveCore", package: "ArchiveCore")],
            resources: [.process("Resources")]
        ),
    ]
)
