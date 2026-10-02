// swift-tools-version: 5.9
import PackageDescription

// StrideeHealth — Apple Health (HealthKit) for the Stridee developer platform.
//
// Developed here in the monorepo, beside the API it talks to, and mirrored to a
// public repository for distribution: Swift Package Manager needs `Package.swift`
// at the root of the repository a dependency points at, which a subdirectory of
// this monorepo cannot be. The Stridee app consumes it by local path, so it is
// the first client of every change.
//
// iOS 17 is the floor: it is where HealthKit gained cycling power and cadence,
// which the workout export reads (sleep stages and wrist temperature are 16).
// Swift 5 language mode, for parity with the Stridee apps.
let package = Package(
    name: "StrideeHealth",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "StrideeHealth", targets: ["StrideeHealth"]),
    ],
    targets: [
        .target(name: "StrideeHealth"),
        .testTarget(name: "StrideeHealthTests", dependencies: ["StrideeHealth"]),
    ],
    swiftLanguageVersions: [.v5]
)
