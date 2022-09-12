// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "swiftsql",
    products: [
        .library(name: "SwiftSQL", targets: ["SwiftSQL"]),
        .executable(name: "swiftsql", targets: ["swiftsql"]),
    ],
    targets: [
        .target(name: "SwiftSQL"),
        .executableTarget(name: "swiftsql", dependencies: ["SwiftSQL"], path: "Sources/CLI"),
        .testTarget(name: "SwiftSQLTests", dependencies: ["SwiftSQL"]),
    ]
)
