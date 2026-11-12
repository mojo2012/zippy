// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchiveCore",
    platforms: [.macOS("15.4")],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .executable(name: "archivetool", targets: ["archivetool"]),
    ],
    targets: [
        // libarchive, gebaut von scripts/build-libarchive.sh
        .binaryTarget(name: "CArchive", path: "Vendor/CArchive.xcframework"),
        .target(name: "ArchiveCore", dependencies: ["CArchive"]),
        .executableTarget(name: "archivetool", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    ]
)
