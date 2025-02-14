// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "AutoDB",
	platforms: [ .macOS(.v14), .iOS(.v17), .tvOS(.v13)],	//go down to iOS(.v13) when time to rewrite tests
	products: [
		// Products define the executables and libraries a package produces, and make them visible to other packages.
		.library(
			name: "AutoDB",
			targets: ["AutoDB"]),
	],
	dependencies: [
		.package(url: "https://github.com/skiptools/swift-sqlcipher.git", from: "1.2.0")
	],
	targets: [
		// Targets are the basic building blocks of a package. A target can define a module or a test suite.
		// Targets can depend on other targets in this package, and on products in packages this package depends on.
		.target(
			name: "AutoDB",
			dependencies: [
				// for other oses we need a SQLite lib, this guarantees one exists and that it has FTS support (which might not be the case otherwise).
				.product(name: "SQLCipher", package: "swift-sqlcipher", condition: .when(platforms: [.android, .linux, .windows, .wasi])),
			]),
		.testTarget(
			name: "AutoDBTests",
			dependencies: ["AutoDB"]),
	]
)
