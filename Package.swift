// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "DaywellCore",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "DaywellCore", targets: ["DaywellCore"])],
  targets: [
    .target(name: "DaywellCore"),
    .testTarget(name: "DaywellCoreTests", dependencies: ["DaywellCore"]),
  ]
)
