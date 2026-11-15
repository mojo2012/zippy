// swift-tools-version: 6.0
import PackageDescription

// FUSE-Header liegen in Sources/CFuseT/include/fuse (aus FUSE-T, LGPL).
// Die Bibliothek wird erst zur Laufzeit geladen (dlopen), damit Zippy
// ohne FUSE-T startet und einen Hinweis zeigen kann.
let package = Package(
    name: "FuseMount",
    defaultLocalization: "en",   // Meldungen: Sources/FuseMount/Resources/Localizable.xcstrings
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
