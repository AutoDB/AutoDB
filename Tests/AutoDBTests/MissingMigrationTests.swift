//
//  MissingMigrationTests.swift
//  AutoDB
//
//  A table whose settings say it has a migration (performMigration) stops when the default runs instead, so a migration with another
//  signature can't go unnoticed. And a migration runs in the transaction of its schema change: a failure leaves the table as it was.
//  (A Feeds build added a column whose copy migration was never called - an old signature, or a second transaction that failed after the
//  column was committed. The column stayed empty for good, and sync spread it.)
//

import Foundation
import Testing
@testable import AutoDB

private let migratingSettings = AutoDBSettings.regular.performingMigration()

/// says it has a migration, has none
struct FlaggedNoMigration: Table {
	static let tableName = "FlaggedNoMigration"
	static var autoDBSettings: AutoDBSettings { migratingSettings }
	var id: AutoId = 1
	var added: String? = nil
}

/// the trap: a function that looks like the migration but has another signature
struct FlaggedWrongSignature: Table {
	static let tableName = "FlaggedWrongSignature"
	static var autoDBSettings: AutoDBSettings { migratingSettings }
	var id: AutoId = 1
	var added: String? = nil
	
	static func migration(_ token: AutoId?, _ db: isolated Database, _ state: MigrationState) async {}
}

struct FlaggedWithMigration: Table {
	static let tableName = "FlaggedWithMigration"
	static var autoDBSettings: AutoDBSettings { migratingSettings }
	var id: AutoId = 1
	var added: String? = nil
	
	static func migration(_ db: isolated Database, _ state: MigrationState) async throws {
		if case .newColumn(let column) = state, column.name == "added" {
			try await db.execute("UPDATE FlaggedWithMigration SET added = 'filled'")
		}
	}
}

/// no flag: auto-migration, and a migration of its own still runs
struct UnflaggedWithMigration: Table {
	static let tableName = "UnflaggedWithMigration"
	var id: AutoId = 1
	var added: String? = nil
	
	static func migration(_ db: isolated Database, _ state: MigrationState) async throws {
		if case .newColumn(let column) = state, column.name == "added" {
			try await db.execute("UPDATE UnflaggedWithMigration SET added = 'filled'")
		}
	}
}

/// no flag, no migration: auto-migration alone, the common case
struct AutoMigratedOnly: Table {
	static let tableName = "AutoMigratedOnly"
	var id: AutoId = 1
	var added: String? = nil
}

struct FailingMigration: Table {
	enum Failure: Error {
		case copyFailed
	}
	static let tableName = "FailingMigration"
	static var autoDBSettings: AutoDBSettings { migratingSettings }
	nonisolated(unsafe) static var fails = true
	var id: AutoId = 1
	var added: String? = nil
	
	static func migration(_ db: isolated Database, _ state: MigrationState) async throws {
		guard case .newColumn(let column) = state, column.name == "added" else {
			return
		}
		try await db.execute("UPDATE FailingMigration SET added = 'filled'")
		if fails {
			throw Failure.copyFailed
		}
	}
}

@Suite(.autoDB, .serialized)
struct MissingMigrationTests {
	
	/// the table as an older version left it, without the `added` column
	private static func createOldTable(_ name: String) async throws {
		let db = try await MigrationHarness.db()
		_ = try? await db.execute("DROP TABLE `\(name)`")
		try await db.execute("CREATE TABLE `\(name)` (`id` INTEGER NOT NULL DEFAULT 1, PRIMARY KEY (`id`))")
		try await db.execute("INSERT INTO `\(name)` (id) VALUES (1)")
	}
	
	private static func columns(_ name: String) async throws -> Set<String> {
		let rows = try await MigrationHarness.db().query("PRAGMA table_info('\(name)')")
		return Set(rows.compactMap { $0["name"]?.stringValue })
	}
	
	/// a database of its own in a temporary folder, the exit test runs in a child process
	private static func inFreshDatabase(_ action: @Sendable () async throws -> Void) async throws {
		let folder = FileManager.default.temporaryDirectory.appending(path: "AutoDBMissingMigration-\(UUID().uuidString)")
		try await AutoDBManager.withScope(AutoDBManager(root: folder)) {
			try await action()
		}
	}
	
	@Test func autoMigrationNeedsNoMigration() async throws {
		try await Self.createOldTable(AutoMigratedOnly.tableName)
		let row = try await AutoMigratedOnly.fetchId(1)
		#expect(row.added == nil)
		#expect(try await Self.columns(AutoMigratedOnly.tableName).contains("added"))
	}
	
	@Test func ownMigrationRunsWithoutTheFlag() async throws {
		try await Self.createOldTable(UnflaggedWithMigration.tableName)
		#expect(try await UnflaggedWithMigration.fetchId(1).added == "filled")
	}
	
	@Test func ownMigrationRunsWithTheFlag() async throws {
		try await Self.createOldTable(FlaggedWithMigration.tableName)
		#expect(try await FlaggedWithMigration.fetchId(1).added == "filled")
	}
	
	@Test func flaggedCreatedTableNeedsNoMigration() async throws {
		_ = try await FlaggedNoMigration.create(1)
	}
	
	// exit tests run the code in a child process, which Swift Testing only supports on these platforms
	#if os(macOS) || os(Linux) || os(Windows)
		@Test func flaggedSchemaChangeWithoutMigrationStops() async {
			await #expect(processExitsWith: .failure) {
				try await Self.inFreshDatabase {
					try await Self.createOldTable(FlaggedNoMigration.tableName)
					_ = try await FlaggedNoMigration.fetchId(1)
				}
			}
		}
		
		@Test func migrationWithAnotherSignatureStops() async {
			await #expect(processExitsWith: .failure) {
				try await Self.inFreshDatabase {
					try await Self.createOldTable(FlaggedWrongSignature.tableName)
					_ = try await FlaggedWrongSignature.fetchId(1)
				}
			}
		}
		
		/// the control of the two above: the same child process with a migration of its own exits normally, so they stop at the assertion, not on an error of the harness
		@Test func flaggedWithMigrationExitsNormally() async {
			await #expect(processExitsWith: .success) {
				try await Self.inFreshDatabase {
					try await Self.createOldTable(FlaggedWithMigration.tableName)
					if try await FlaggedWithMigration.fetchId(1).added != "filled" {
						exit(1)
					}
				}
			}
		}
	#endif
	
	/// a migration that fails takes its schema change with it: the column is not there, so the next use gets the `.newColumn` again
	@Test func failedMigrationRollsBackTheSchemaChange() async throws {
		FailingMigration.fails = true
		try await Self.createOldTable(FailingMigration.tableName)
		await #expect(throws: FailingMigration.Failure.copyFailed) {
			_ = try await FailingMigration.fetchId(1)
		}
		#expect(try await Self.columns(FailingMigration.tableName) == ["id"], "the added column was rolled back with the migration")
		
		FailingMigration.fails = false
		#expect(try await FailingMigration.fetchId(1).added == "filled", "the next use migrated again")
	}
}
