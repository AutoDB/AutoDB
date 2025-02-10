// swift-tools-version: 6.0
import PackageDescription

var package = Package(
    name: "AutoDB",
    platforms: [ .macOS(.v14), .iOS(.v13), .tvOS(.v13)],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "AutoDB",
            targets: ["AutoDB"]),
    ],
    dependencies: [
        
        //use a subset of GRDB to port to linux
		//.package(name: "GRDB", url: "https://github.com/groue/GRDB.swift.git", from: "6.26.0"),
        
        //.package(url: "https://github.com/ahti/SQLeleCoder.git", from: "0.0.1"),
        //This doesn't load, why?
        //.package(url: "https://github.com/apple/swift-collections.git", from: "0.0.1")
    ],
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
