// swift-tools-version: 6.1
import PackageDescription

let package = Package(
	name: "AutoDB",
	platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10)],
	products: [
		.library(
			name: "AutoDB",
			type: .static,
			targets: ["AutoDB"]
		),
		// Swift Testing traits that give each suite its own databases, see Documentation.md "Scopes and testing"
		.library(
			name: "AutoDBTesting",
			targets: ["AutoDBTesting"]
		),
	],
	traits: [
		.trait(name: "SQLCipher", description: "Use skip's SQLCipher (SQLite with encryption) instead of the system SQLite. Required on Android and Linux, enables AutoDBSettings.encrypted().")
	],
	// only fetched when the SQLCipher trait is enabled, Apple-only users keep the system SQLite and download nothing extra
	dependencies: [
		.package(url: "https://github.com/skiptools/swift-sqlcipher.git", from: "1.13.0")
	],
	targets: [
		.target(
			name: "AutoDB",
			dependencies: [
				.product(name: "SQLCipher", package: "swift-sqlcipher", condition: .when(traits: ["SQLCipher"]))
			],
			// sqlite3.h only declares sqlite3_key_v2 and friends with this defined
			cSettings: [.define("SQLITE_HAS_CODEC", .when(traits: ["SQLCipher"]))]
		),
		.target(
			name: "AutoDBTesting",
			dependencies: ["AutoDB"]
		),
		.testTarget(
			name: "AutoDBTests",
			dependencies: ["AutoDB", "AutoDBTesting"]
		),
		.testTarget(
			name: "AutoDBIntegrationTests",
			dependencies: ["AutoDB"]
		),
	]
)
