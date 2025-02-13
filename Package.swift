// swift-tools-version: 6.0
import PackageDescription

var package = Package(
    name: "AutoDB",
    platforms: [ .macOS(.v14), .iOS(.v17), .tvOS(.v13)],	//go down to iOS(.v13) when time to rewrite tests
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "AutoDB",
            targets: ["AutoDB"]),
    ],
    dependencies: [],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "AutoDB",
            dependencies: []),
        .testTarget(
            name: "AutoDBTests",
            dependencies: ["AutoDB"]),
    ]
)
//package.platforms = [.macOS("14.0"), .iOS("13.0"), .tvOS("13.0"), .watchOS("6.0")]
