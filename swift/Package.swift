// swift-tools-version:5.9
// Skeleton only: the target has no sources yet. See README.md.
import PackageDescription

let package = Package(
    name: "FourDGS",
    platforms: [.visionOS(.v1), .iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FourDGS", targets: ["FourDGS"])
    ],
    targets: [
        .target(name: "FourDGS")
    ]
)
