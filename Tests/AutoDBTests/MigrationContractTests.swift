//
//  MigrationContractTests.swift
//  AutoDB
//
//  Created by Codex on 2026-05-06.
//

import Foundation
import Testing

@testable import AutoDB

struct MigrationHarness: Table {
	static let tableName = "MigrationHarness"
	var id: AutoId = 1
}

struct AddRemoveColumnsTarget: Table {
	static let tableName = "AddRemoveColumnsTarget"
	var id: AutoId = 1
	var kept = "kept"
	var added: String? = nil
}

struct OptionalWidenTarget: Table {
	static let tableName = "OptionalWidenTarget"
	var id: AutoId = 1
	var title: String? = nil
}

struct OptionalTightenTarget: Table {
	static let tableName = "OptionalTightenTarget"
	var id: AutoId = 1
	var title = "fallback"
}

struct OptionalTightenNullTarget: Table {
	static let tableName = "OptionalTightenNullTarget"
	var id: AutoId = 1
	var title = "fallback"
}

struct NumericStringToIntTarget: Table {
	static let tableName = "NumericStringToIntTarget"
	var id: AutoId = 1
	var number = 67
}

struct IntegerToStringTarget: Table {
	static let tableName = "IntegerToStringTarget"
	var id: AutoId = 1
	var number = "fallback"
}

struct GarbageStringToIntTarget: Table {
	static let tableName = "GarbageStringToIntTarget"
	var id: AutoId = 1
	var number = 67
}

struct IntegerWidthTarget: Table {
	static let tableName = "IntegerWidthTarget"
	var id: AutoId = 1
	var number: Int64 = 0
}

struct EnumMigrationTarget: Table {
	static let tableName = "EnumMigrationTarget"
	var id: AutoId = 1
	var plain = PrimitiveStringEnum.alpha
	var signed = PrimitiveIntEnum.first
	var unsigned = PrimitiveUIntEnum.first
}

struct RichStorageMigrationTarget: Table {
	static let tableName = "RichStorageMigrationTarget"
	var id: AutoId = 1
	var website = URL(string: "https://autodb.dev")!
	var createdAt = Date(timeIntervalSince1970: 1)
	var blob = Data([0x01])
	var payload = BlobPayload(nested: NestedBlobPayload(title: "payload", count: 1), tags: ["default"])
}

@Suite("Migration Contract", .serialized)
struct MigrationContractTests {
	private func migrationDB() async throws -> Database {
		try await MigrationHarness.db()
	}

	private func schemaMap(_ tableName: String, db: Database) async throws -> [String: (type: String, nullable: Bool)] {
		let rows = try await db.query("PRAGMA table_info('\(tableName)')")
		var result: [String: (type: String, nullable: Bool)] = [:]
		for row in rows {
			guard let name = row["name"]?.stringValue,
			      let type = row["type"]?.stringValue,
			      let notNull = row["notnull"]?.boolValue else {
				continue
			}
			result[name] = (type, !notNull)
		}
		return result
	}

	@Test
	func addAndRemoveColumnsPreserveExistingRows() async throws {
		let db = try await migrationDB()
		_ = try? await db.execute("DROP TABLE AddRemoveColumnsTarget")
		try await db.execute("""
		CREATE TABLE `AddRemoveColumnsTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`kept` TEXT NOT NULL DEFAULT '',
			`removed` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO AddRemoveColumnsTarget (id, kept, removed) VALUES (1, 'still here', 'legacy')")

		let fetched = try await AddRemoveColumnsTarget.fetchId(1)
		#expect(fetched.kept == "still here")
		#expect(fetched.added == nil)

		let schema = try await schemaMap(AddRemoveColumnsTarget.tableName, db: db)
		#expect(schema["kept"]?.type == "TEXT")
		#expect(schema["added"]?.type == "TEXT")
		#expect(schema["removed"] == nil)
	}

	@Test
	func optionalityMigrationHandlesWideningAndSafeTightening() async throws {
		let db = try await migrationDB()

		_ = try? await db.execute("DROP TABLE OptionalWidenTarget")
		try await db.execute("""
		CREATE TABLE `OptionalWidenTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`title` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO OptionalWidenTarget (id, title) VALUES (1, 'required before')")

		let widened = try await OptionalWidenTarget.fetchId(1)
		#expect(widened.title == "required before")
		let widenedSchema = try await schemaMap(OptionalWidenTarget.tableName, db: db)
		#expect(widenedSchema["title"]?.nullable == true)

		_ = try? await db.execute("DROP TABLE OptionalTightenTarget")
		try await db.execute("""
		CREATE TABLE `OptionalTightenTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`title` TEXT NULL DEFAULT NULL,
			`legacy` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO OptionalTightenTarget (id, title, legacy) VALUES (1, 'safe tighten', 'drop me')")

		let tightened = try await OptionalTightenTarget.fetchId(1)
		#expect(tightened.title == "safe tighten")
		let tightenedSchema = try await schemaMap(OptionalTightenTarget.tableName, db: db)
		#expect(tightenedSchema["title"]?.nullable == false)
		#expect(tightenedSchema["legacy"] == nil)
	}

	@Test
	func optionalToRequiredWithNullRowsCurrentlyFallsBackToDefaultValue() async throws {
		let db = try await migrationDB()
		_ = try? await db.execute("DROP TABLE OptionalTightenNullTarget")
		try await db.execute("""
		CREATE TABLE `OptionalTightenNullTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`title` TEXT NULL DEFAULT NULL,
			`legacy` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO OptionalTightenNullTarget (id, title, legacy) VALUES (1, NULL, 'drop me')")

		let fetched = try await OptionalTightenNullTarget.fetchId(1)
		#expect(fetched.title == "")

		let schema = try await schemaMap(OptionalTightenNullTarget.tableName, db: db)
		#expect(schema["title"]?.nullable == false)
		#expect(schema["legacy"] == nil)
	}

	@Test
	func primitiveTypeConversionsMatchCurrentAutoMigrationContract() async throws {
		let db = try await migrationDB()

		_ = try? await db.execute("DROP TABLE NumericStringToIntTarget")
		try await db.execute("""
		CREATE TABLE `NumericStringToIntTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`number` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO NumericStringToIntTarget (id, number) VALUES (1, '42')")

		let numericToInt = try await NumericStringToIntTarget.fetchId(1)
		#expect(numericToInt.number == 42)
		let numericSchema = try await schemaMap(NumericStringToIntTarget.tableName, db: db)
		#expect(numericSchema["number"]?.type == "INTEGER")

		_ = try? await db.execute("DROP TABLE IntegerToStringTarget")
		try await db.execute("""
		CREATE TABLE `IntegerToStringTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`number` INTEGER NOT NULL DEFAULT 0,
			`legacy` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO IntegerToStringTarget (id, number, legacy) VALUES (1, 42, 'drop me')")

		let intToString = try await IntegerToStringTarget.fetchId(1)
		#expect(intToString.number == "42")
		let intToStringSchema = try await schemaMap(IntegerToStringTarget.tableName, db: db)
		#expect(intToStringSchema["number"]?.type == "TEXT")

		_ = try? await db.execute("DROP TABLE GarbageStringToIntTarget")
		try await db.execute("""
		CREATE TABLE `GarbageStringToIntTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`number` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO GarbageStringToIntTarget (id, number) VALUES (1, 'not a number')")

		let garbage = try await GarbageStringToIntTarget.fetchId(1)
		let rawGarbage = try #require(try await GarbageStringToIntTarget.query("SELECT * FROM GarbageStringToIntTarget WHERE id = 1").first)
		#expect(garbage.number == 67)
		#expect(rawGarbage["number"]?.stringValue == "not a number")
		#expect(rawGarbage["number"]?.intValue == nil)

		_ = try? await db.execute("DROP TABLE IntegerWidthTarget")
		try await db.execute("""
		CREATE TABLE `IntegerWidthTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`number` INTEGER NOT NULL DEFAULT 0,
			`legacy` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO IntegerWidthTarget (id, number, legacy) VALUES (1, 2147483647, 'drop me')")

		let width = try await IntegerWidthTarget.fetchId(1)
		#expect(width.number == 2_147_483_647)
	}

	@Test
	func rawValueEnumsStayPrimitiveAcrossMigration() async throws {
		let db = try await migrationDB()
		_ = try? await db.execute("DROP TABLE EnumMigrationTarget")
		try await db.execute("""
		CREATE TABLE `EnumMigrationTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`plain` TEXT NOT NULL DEFAULT 'alpha',
			`signed` INTEGER NOT NULL DEFAULT 1,
			`unsigned` INTEGER NOT NULL DEFAULT 1,
			`legacy` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")
		try await db.execute("INSERT INTO EnumMigrationTarget (id, plain, signed, unsigned, legacy) VALUES (1, 'beta', 2, 2, 'drop me')")

		let fetched = try await EnumMigrationTarget.fetchId(1)
		#expect(fetched.plain == .beta)
		#expect(fetched.signed == .second)
		#expect(fetched.unsigned == .second)

		let schema = try await schemaMap(EnumMigrationTarget.tableName, db: db)
		#expect(schema["plain"]?.type == "TEXT")
		#expect(schema["signed"]?.type == "INTEGER")
		#expect(schema["unsigned"]?.type == "INTEGER")
	}

	@Test
	func urlDateDataAndBlobPayloadSurviveAutomaticRebuildMigrations() async throws {
		let db = try await migrationDB()
		_ = try? await db.execute("DROP TABLE RichStorageMigrationTarget")
		try await db.execute("""
		CREATE TABLE `RichStorageMigrationTarget` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`website` TEXT NOT NULL DEFAULT '',
			`createdAt` DOUBLE NOT NULL DEFAULT 0,
			`blob` BLOB NOT NULL DEFAULT X'',
			`payload` BLOB NOT NULL DEFAULT X'',
			`legacy` TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (`id`)
		)
		""")

		let expectedURL = URL(string: "https://autodb.dev/migration")!
		let expectedDate = Date(timeIntervalSince1970: 321_654)
		let expectedBlob = Data([0xCA, 0xFE])
		let expectedPayload = BlobPayload(
			nested: NestedBlobPayload(title: "migrated", count: 4),
			tags: ["blob", "payload"]
		)
		let encodedPayload = try JSONEncoder().encode(expectedPayload)

		try await db.execute(
			"INSERT INTO RichStorageMigrationTarget (id, website, createdAt, blob, payload, legacy) VALUES (?, ?, ?, ?, ?, ?)",
			[
				AutoId(1),
				expectedURL.absoluteString,
				expectedDate.timeIntervalSince1970,
				expectedBlob,
				encodedPayload,
				"drop me",
			]
		)

		let fetched = try await RichStorageMigrationTarget.fetchId(1)
		#expect(fetched.website == expectedURL)
		#expect(fetched.createdAt == expectedDate)
		#expect(fetched.blob == expectedBlob)
		#expect(fetched.payload == expectedPayload)

		let schema = try await schemaMap(RichStorageMigrationTarget.tableName, db: db)
		#expect(schema["website"]?.type == "TEXT")
		#expect(schema["createdAt"]?.type == "DOUBLE")
		#expect(schema["blob"]?.type == "BLOB")
		#expect(schema["payload"]?.type == "BLOB")
		#expect(schema["legacy"] == nil)
	}
}
