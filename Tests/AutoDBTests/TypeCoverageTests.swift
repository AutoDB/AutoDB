//
//  TypeCoverageTests.swift
//  AutoDB
//
//  Created by Codex on 2026-05-06.
//

import Foundation
import Testing

@testable import AutoDB

enum PlainStringRawEnum: String, Codable, Sendable {
	case alpha
	case beta
}

enum PrimitiveStringEnum: String, SQLStringEnum, Codable, Sendable, CaseIterable {
	typealias RawValue = String

	case alpha = "alpha"
	case beta = "beta"
}

enum PrimitiveIntEnum: Int, SQLIntegerEnum, Codable, Sendable, CaseIterable {
	typealias RawValue = Int

	case first = 1
	case second = 2
}

enum PrimitiveUIntEnum: UInt64, SQLUIntegerEnum, Codable, Sendable, CaseIterable {
	typealias RawValue = UInt64

	case first = 1
	case second = 2
}

struct NestedBlobPayload: Codable, Hashable, Sendable {
	var title: String
	var count: Int
}

struct BlobPayload: Codable, Hashable, Sendable {
	var nested: NestedBlobPayload
	var tags: [String]
}

struct BlobPayloadV2: Codable, Hashable, Sendable {
	var nested: NestedBlobPayload
	var tags: [String]
	var note: String?
}

struct TypeMatrixRow: Table {
	static let tableName = "TypeMatrixRow"

	var id: AutoId = 1
	var string = "hello"
	var optionalString: String? = nil
	var plainStringEnum: PlainStringRawEnum = .alpha
	var stringEnum: PrimitiveStringEnum = .alpha
	var optionalStringEnum: PrimitiveStringEnum? = nil
	var bool = true
	var optionalBool: Bool? = nil
	var doubleValue = 12.5
	var optionalDouble: Double? = nil
	var floatValue: Float = 1.25
	var date = Date(timeIntervalSince1970: 123_456)
	var optionalDate: Date? = nil
	var data = Data([0x41, 0x42, 0x43])
	var optionalData: Data? = nil
	var intValue = -12
	var int8Value: Int8 = -8
	var int16Value: Int16 = -1_600
	var int32Value: Int32 = -32_000
	var int64Value: Int64 = -64_000
	var optionalInt: Int? = nil
	var uintValue: UInt = 12
	var uint8Value: UInt8 = 8
	var uint16Value: UInt16 = 1_600
	var uint32Value: UInt32 = 32_000
	var uint64Value: UInt64 = 64_000
	var optionalUInt64: UInt64? = nil
	var url = URL(string: "https://autodb.dev/type-matrix")!
	var optionalURL: URL? = nil
	var autoId128 = AutoId128(rawValue: Data(0..<16))
	var optionalAutoId128: AutoId128? = nil
	var signedEnum: PrimitiveIntEnum = .first
	var optionalSignedEnum: PrimitiveIntEnum? = nil
	var unsignedEnum: PrimitiveUIntEnum = .first
	var optionalUnsignedEnum: PrimitiveUIntEnum? = nil
	var payload = BlobPayload(nested: NestedBlobPayload(title: "payload", count: 3), tags: ["swift", "sqlite"])
	var optionalPayload: BlobPayload? = nil
}

struct PayloadEvolutionRow: Table {
	static let tableName = "PayloadEvolutionRow"

	var id: AutoId = 1
	var payload = BlobPayloadV2(nested: NestedBlobPayload(title: "payload", count: 0), tags: [], note: nil)
}

@Suite("Type Coverage", .serialized)
struct TypeCoverageTests {
	private func schemaMap<TableType: Table>(for table: TableType.Type) async throws -> [String: (type: String, nullable: Bool)] {
		let db = try await table.db()
		let rows = try await db.query("PRAGMA table_info('\(table.tableName)')")
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
	func sqlNativeSchemaMatchesStoredPrimitiveTypes() async throws {
		let schema = try await schemaMap(for: TypeMatrixRow.self)

		#expect(schema["string"]?.type == "TEXT")
		#expect(schema["optionalString"]?.type == "TEXT")
		#expect(schema["plainStringEnum"]?.type == "TEXT")
		#expect(schema["stringEnum"]?.type == "TEXT")
		#expect(schema["optionalStringEnum"]?.type == "TEXT")
		#expect(schema["url"]?.type == "TEXT")
		#expect(schema["optionalURL"]?.type == "TEXT")

		#expect(schema["bool"]?.type == "INTEGER")
		#expect(schema["optionalBool"]?.type == "INTEGER")
		#expect(schema["intValue"]?.type == "INTEGER")
		#expect(schema["int8Value"]?.type == "INTEGER")
		#expect(schema["int16Value"]?.type == "INTEGER")
		#expect(schema["int32Value"]?.type == "INTEGER")
		#expect(schema["int64Value"]?.type == "INTEGER")
		#expect(schema["optionalInt"]?.type == "INTEGER")
		#expect(schema["uintValue"]?.type == "INTEGER")
		#expect(schema["uint8Value"]?.type == "INTEGER")
		#expect(schema["uint16Value"]?.type == "INTEGER")
		#expect(schema["uint32Value"]?.type == "INTEGER")
		#expect(schema["uint64Value"]?.type == "INTEGER")
		#expect(schema["optionalUInt64"]?.type == "INTEGER")
		#expect(schema["signedEnum"]?.type == "INTEGER")
		#expect(schema["optionalSignedEnum"]?.type == "INTEGER")
		#expect(schema["unsignedEnum"]?.type == "INTEGER")
		#expect(schema["optionalUnsignedEnum"]?.type == "INTEGER")

		#expect(schema["doubleValue"]?.type == "DOUBLE")
		#expect(schema["optionalDouble"]?.type == "DOUBLE")
		#expect(schema["floatValue"]?.type == "DOUBLE")
		#expect(schema["date"]?.type == "DOUBLE")
		#expect(schema["optionalDate"]?.type == "DOUBLE")

		#expect(schema["data"]?.type == "BLOB")
		#expect(schema["optionalData"]?.type == "BLOB")
		#expect(schema["autoId128"]?.type == "BLOB")
		#expect(schema["optionalAutoId128"]?.type == "BLOB")
		#expect(schema["payload"]?.type == "BLOB")
		#expect(schema["optionalPayload"]?.type == "BLOB")

		#expect(schema["optionalString"]?.nullable == true)
		#expect(schema["optionalBool"]?.nullable == true)
		#expect(schema["optionalDouble"]?.nullable == true)
		#expect(schema["optionalDate"]?.nullable == true)
		#expect(schema["optionalData"]?.nullable == true)
		#expect(schema["optionalInt"]?.nullable == true)
		#expect(schema["optionalUInt64"]?.nullable == true)
		#expect(schema["optionalURL"]?.nullable == true)
		#expect(schema["optionalAutoId128"]?.nullable == true)
		#expect(schema["optionalStringEnum"]?.nullable == true)
		#expect(schema["optionalSignedEnum"]?.nullable == true)
		#expect(schema["optionalUnsignedEnum"]?.nullable == true)
		#expect(schema["optionalPayload"]?.nullable == true)
	}

	@Test
	func roundTripsNativeAndBlobBackedTypes() async throws {
		try await TypeMatrixRow.truncateTable()

		var row = await TypeMatrixRow.create(42)
		row.string = "stored"
		row.optionalString = "optional"
		row.plainStringEnum = .beta
		row.stringEnum = .beta
		row.optionalStringEnum = .alpha
		row.bool = false
		row.optionalBool = true
		row.doubleValue = 91.125
		row.optionalDouble = 72.25
		row.floatValue = 3.5
		row.date = Date(timeIntervalSince1970: 987_654)
		row.optionalDate = Date(timeIntervalSince1970: 123)
		row.data = Data([0xDE, 0xAD, 0xBE, 0xEF])
		row.optionalData = Data([0xAA, 0xBB])
		row.intValue = -99
		row.int8Value = -5
		row.int16Value = -1_234
		row.int32Value = -12_345
		row.int64Value = -123_456
		row.optionalInt = 54
		row.uintValue = 99
		row.uint8Value = 5
		row.uint16Value = 1_234
		row.uint32Value = 12_345
		row.uint64Value = 123_456
		row.optionalUInt64 = 654_321
		row.url = URL(string: "https://autodb.dev/round-trip")!
		row.optionalURL = URL(string: "https://autodb.dev/optional")!
		row.autoId128 = AutoId128(rawValue: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]))
		row.optionalAutoId128 = AutoId128(rawValue: Data([15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]))
		row.signedEnum = .second
		row.optionalSignedEnum = .first
		row.unsignedEnum = .second
		row.optionalUnsignedEnum = .first
		row.payload = BlobPayload(nested: NestedBlobPayload(title: "nested", count: 8), tags: ["swift", "autodb"])
		row.optionalPayload = BlobPayload(nested: NestedBlobPayload(title: "optional", count: 9), tags: ["blob"])
		try await row.save()

		let fetched = try await TypeMatrixRow.fetchId(42)
		#expect(fetched == row)

		let rawRow = try #require(try await TypeMatrixRow.query("SELECT * FROM TypeMatrixRow WHERE id = ?", [row.id]).first)
		#expect(rawRow["string"]?.stringValue == row.string)
		#expect(rawRow["plainStringEnum"]?.stringValue == row.plainStringEnum.rawValue)
		#expect(rawRow["stringEnum"]?.stringValue == row.stringEnum.rawValue)
		#expect(rawRow["optionalStringEnum"]?.stringValue == row.optionalStringEnum?.rawValue)
		#expect(rawRow["bool"]?.boolValue == row.bool)
		#expect(rawRow["optionalBool"]?.boolValue == row.optionalBool)
		#expect(rawRow["doubleValue"]?.doubleValue == row.doubleValue)
		#expect(rawRow["floatValue"]?.doubleValue == Double(row.floatValue))
		#expect(rawRow["date"]?.doubleValue == row.date.timeIntervalSince1970)
		#expect(rawRow["data"]?.dataValue == row.data)
		#expect(rawRow["autoId128"]?.dataValue == row.autoId128.rawValue)
		#expect(rawRow["intValue"]?.intValue == row.intValue)
		#expect(rawRow["uint64Value"]?.uint64Value == row.uint64Value)
		#expect(rawRow["url"]?.stringValue == row.url.absoluteString)
		#expect(rawRow["signedEnum"]?.intValue == row.signedEnum.rawValue)
		#expect(rawRow["unsignedEnum"]?.uint64Value == row.unsignedEnum.rawValue)
		#expect(rawRow["payload"]?.dataValue != nil)
		#expect(rawRow["optionalPayload"]?.dataValue != nil)
	}

	@Test
	func enumColumnsStayQueryableAsPrimitiveStorage() async throws {
		try await TypeMatrixRow.truncateTable()

		var row = await TypeMatrixRow.create(7)
		row.plainStringEnum = .beta
		row.stringEnum = .beta
		row.optionalStringEnum = .alpha
		row.signedEnum = .second
		row.optionalSignedEnum = .first
		row.unsignedEnum = .second
		row.optionalUnsignedEnum = .first
		try await row.save()

		let byEnums = try await TypeMatrixRow.fetchQuery(
			"WHERE plainStringEnum = ? AND stringEnum = ? AND optionalStringEnum = ? AND signedEnum = ? AND optionalSignedEnum = ? AND unsignedEnum = ? AND optionalUnsignedEnum = ?",
			[
				PlainStringRawEnum.beta,
				PrimitiveStringEnum.beta,
				PrimitiveStringEnum.alpha,
				PrimitiveIntEnum.second,
				PrimitiveIntEnum.first,
				PrimitiveUIntEnum.second,
				PrimitiveUIntEnum.first,
			]
		)
		#expect(byEnums.count == 1)
		#expect(byEnums.first?.id == row.id)

		let byRawValues = try await TypeMatrixRow.fetchQuery(
			"WHERE plainStringEnum = ? AND stringEnum = ? AND signedEnum = ? AND unsignedEnum = ?",
			[
				PlainStringRawEnum.beta.rawValue,
				PrimitiveStringEnum.beta.rawValue,
				PrimitiveIntEnum.second.rawValue,
				PrimitiveUIntEnum.second.rawValue,
			]
		)
		#expect(byRawValues.count == 1)
		#expect(byRawValues.first?.id == row.id)
	}

	@Test
	func blobPayloadEvolutionDecodesAddedOptionalFields() async throws {
		let db = try await PayloadEvolutionRow.db()
		_ = try? await db.execute("DROP TABLE PayloadEvolutionRow")
		try await db.execute("""
		CREATE TABLE `PayloadEvolutionRow` (
			`id` INTEGER NOT NULL DEFAULT 1,
			`payload` BLOB NOT NULL DEFAULT X'',
			PRIMARY KEY (`id`)
		)
		""")

		let legacy = BlobPayload(nested: NestedBlobPayload(title: "legacy", count: 11), tags: ["old"])
		let legacyData = try JSONEncoder().encode(legacy)
		try await db.execute("INSERT INTO PayloadEvolutionRow (id, payload) VALUES (?, ?)", [AutoId(1), legacyData])

		let fetched = try await PayloadEvolutionRow.fetchId(1)
		#expect(fetched.payload.nested.title == "legacy")
		#expect(fetched.payload.nested.count == 11)
		#expect(fetched.payload.tags == ["old"])
		#expect(fetched.payload.note == nil)
	}
}
