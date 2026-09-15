//
//  PartialRowDecodeTests.swift
//  AutoDB
//
//  Decoding a partial row over an existing value (Table.updated(with:)) and reading a table's columns (Table.columns()) -
//  what a sync layer needs to map rows to records without knowing the model.
//

import Foundation
import Testing

@testable import AutoDB

struct PartialRowOptions: OptionSet, Codable, Hashable, Sendable {
	let rawValue: UInt
	static let starred = PartialRowOptions(rawValue: 1 << 0)
	static let muted = PartialRowOptions(rawValue: 1 << 1)
}

struct PartialRowTable: Table {
	static let tableName = "PartialRowTable"
	
	var id: AutoId = 1
	var name: String? = "base name"
	var when = Date(timeIntervalSince1970: 100)
	var flag = false
	var options: PartialRowOptions = []
	var count = 7
}

@Suite("Partial row decoding", .serialized)
struct PartialRowDecodeTests {
	
	@Test func rowColumnsReplaceBaseValuesAndTheRestStays() async throws {
		_ = try await PartialRowTable.db()
		var base = PartialRowTable()
		base.id = 42
		base.count = 9
		
		let result = try await base.updated(with: ["when": .double(1_700_000_000), "flag": .integer(1), "options": .integer(3)])
		
		#expect(result.id == 42, "the base's id is kept")
		#expect(result.count == 9, "an absent non-optional keeps the base's value")
		#expect(result.name == "base name", "an absent optional keeps the base's value")
		#expect(result.when == Date(timeIntervalSince1970: 1_700_000_000))
		#expect(result.flag == true)
		#expect(result.options == [.starred, .muted])
	}
	
	@Test func nullClearsAnOptionalAndTextReplacesIt() async throws {
		_ = try await PartialRowTable.db()
		let base = PartialRowTable()
		
		let cleared = try await base.updated(with: ["name": .null])
		#expect(cleared.name == nil)
		
		let renamed = try await base.updated(with: ["name": .text("other")])
		#expect(renamed.name == "other")
	}
	
	@Test func columnsCarryTheSwiftTypes() async throws {
		let columns = try await PartialRowTable.columns()
		let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })
		
		#expect(byName["when"]?.columnType == .real)
		#expect(byName["when"]?.valueType == Date.self)
		#expect(byName["when"]?.mayBeNull == false)
		#expect(byName["name"]?.columnType == .text)
		#expect(byName["name"]?.mayBeNull == true)
		#expect(byName["options"]?.columnType == .integer)
		#expect(byName["options"]?.valueType == PartialRowOptions.self)
		#expect(byName["flag"]?.valueType == Bool.self)
	}
	
	/// the fetch path is unchanged: a stored row comes back whole, nil optionals included
	@Test func fullRowsStillDecodeWithoutABase() async throws {
		_ = try await PartialRowTable.db()
		try await PartialRowTable.truncateTable()
		var stored = PartialRowTable()
		stored.id = 5
		stored.name = nil
		stored.options = [.muted]
		try await stored.save()
		
		let fetched = try await PartialRowTable.fetchId(5)
		#expect(fetched.name == nil)
		#expect(fetched.options == [.muted])
		#expect(fetched.count == 7)
	}
}
