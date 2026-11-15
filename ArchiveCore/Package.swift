// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchiveCore",
    defaultLocalization: "en",   // messages: Sources/ArchiveCore/Resources/Localizable.xcstrings
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .executable(name: "archivetool", targets: ["archivetool"]),
    ],
    targets: [
        // libarchive, built by scripts/build-libarchive.sh
        .binaryTarget(name: "CArchive", path: "Vendor/CArchive.xcframework"),
        .target(name: "ArchiveCore", dependencies: ["CArchive"], resources: [.process("Resources")]),
        .executableTarget(name: "archivetool", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"],
                    resources: [.copy("Fixtures")]),   // RAR test archives from libarchive
    ]
)
