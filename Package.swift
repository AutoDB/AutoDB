// swift-tools-version: 6.0
import PackageDescription

var package = Package(
	name: "AutoDB",
	platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v13)],
	products: [
		.library(
			name: "AutoDB",
			targets: ["AutoDB"]
		)
	],
	targets: [
		.target(
			name: "AutoDB",
			dependencies: [
				//.product(name: "SQLCipher", package: "swift-sqlcipher", condition: .when(platforms: [.android, .linux, .windows, .wasi])),
			]
		),
		.testTarget(
			name: "AutoDBTests",
			dependencies: ["AutoDB"]
		),
		.testTarget(
			name: "AutoDBIntegrationTests",
			dependencies: ["AutoDB"]
		),
	]
)
// prevent fetching unused dependencies for other platforms, sadly this also prevents cross-compiling since host usually is macOS
#if os(Android) || os(Linux) || os(Windows) || os(wasi)
	package.dependencies = [.package(url: "https://github.com/skiptools/swift-sqlcipher.git", from: "1.2.0")]
	package.targets["AutoDB"].dependencies.append(.product(name: "SQLCipher", package: "swift-sqlcipher"))
#endif
